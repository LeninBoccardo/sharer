import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Slice 5.3 — end-to-end chunk encryption between paired peers.
///
/// Wraps the file body in a frame stream that the receiver can decrypt
/// chunk-by-chunk without buffering the whole payload. Per docs/v1/
/// security.md §8 the construction is:
///
///   transferKey = HKDF-SHA256(PSK, salt=transferId, info="sharer-transfer-v1", 32 bytes)
///
/// For each chunk i:
///   nonce       = transferId(8B) ‖ chunkIndex(4B)            // 12 bytes
///   aad         = nonce                                      // bound into tag
///   ciphertext  = AES-256-GCM(transferKey, nonce, plaintext, aad)
///   wire frame  = chunkIndex(4B BE) ‖ cipherLen(4B BE) ‖ ciphertext+tag(N+16B)
///
/// The transferId travels in an HTTP header (X-Sharer-TransferId) and is
/// covered by the request HMAC, so a tampering attacker can't substitute
/// a different transferId mid-flight without invalidating the signature.
///
/// Per-chunk auth tags catch tampering at the granularity of one chunk.
/// If decryption of any chunk fails the receiver aborts the transfer and
/// deletes the partial file; nothing plaintext is ever exposed.
///
/// Decryption is streaming — plaintext for chunk i is written to disk
/// before chunk i+1's ciphertext finishes downloading. Memory use is
/// bounded by [kPlaintextChunkSize] plus the in-flight frame header.

/// Plaintext chunk size in bytes. 32 KB balances per-chunk overhead
/// (header+tag = 24 B) against latency (smaller = receiver writes earlier
/// on slow links). Picked from the 16–64 KB range docs/v1/security.md
/// §8 calls out.
const int kPlaintextChunkSize = 32 * 1024;

/// 4-byte chunkIndex + 4-byte ciphertextLength.
const int _frameHeaderBytes = 8;

/// AES-256-GCM authentication tag length (fixed by the spec).
const int _gcmTagBytes = 16;

/// AES-GCM nonce length (fixed by the spec). transferId(8B) ‖ chunkIndex(4B).
const int _nonceBytes = 12;

/// Cap on a single ciphertext+tag length on the wire. Chosen so a
/// malicious peer can't trick the receiver into allocating a huge buffer
/// from a forged length header. 64 KB plaintext + 16 B tag = 65 552 B.
const int _maxCipherFrameBytes = 65552;

/// HKDF salt = transferId. transferId is 8 random bytes per send.
const int _transferIdBytes = 8;

/// Length on the wire for a plaintext payload of [plaintextSize] bytes
/// when run through [TransferCipher.encrypt]. Used by the sender to set
/// `Content-Length` correctly — without it the HTTP layer would either
/// chunked-encode or refuse the request.
int encryptedLengthFor(int plaintextSize) {
  if (plaintextSize <= 0) {
    return _frameHeaderBytes + _gcmTagBytes;
  }
  final fullChunks = plaintextSize ~/ kPlaintextChunkSize;
  final tailBytes = plaintextSize % kPlaintextChunkSize;
  final chunkCount = fullChunks + (tailBytes == 0 ? 0 : 1);
  return chunkCount * (_frameHeaderBytes + _gcmTagBytes) + plaintextSize;
}

/// Generate a fresh 8-byte transferId. Caller passes a [Random.secure]
/// in production; tests can pass a seeded [Random] for determinism.
Uint8List newTransferId([Random? random]) {
  final r = random ?? Random.secure();
  final b = Uint8List(_transferIdBytes);
  for (var i = 0; i < b.length; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

class TransferCipher {
  final SecretKey _key;
  final Uint8List _transferId;
  final AesGcm _gcm;

  TransferCipher._(this._key, this._transferId, this._gcm);

  /// Derive a per-transfer cipher from the long-term per-pair PSK and the
  /// fresh per-transfer id. transferId is 8 random bytes the sender
  /// generates and ships in `X-Sharer-TransferId`.
  static Future<TransferCipher> derive({
    required Uint8List psk,
    required Uint8List transferId,
  }) async {
    if (transferId.length != _transferIdBytes) {
      throw ArgumentError.value(transferId.length, 'transferId.length',
          'must be exactly $_transferIdBytes bytes');
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final keyBytes = await hkdf.deriveKey(
      secretKey: SecretKey(psk),
      nonce: transferId,
      info: utf8.encode('sharer-transfer-v1'),
    );
    return TransferCipher._(
      keyBytes,
      Uint8List.fromList(transferId),
      AesGcm.with256bits(),
    );
  }

  /// Re-chunks [plaintext] into fixed-size pieces (the last may be
  /// smaller) and emits frame-encoded ciphertext on the wire. Always
  /// emits at least one frame so a 0-byte payload is distinguishable
  /// from a truncated stream on the wire.
  Stream<List<int>> encrypt(Stream<List<int>> plaintext) async* {
    final buffer = BytesBuilder(copy: false);
    var chunkIndex = 0;
    await for (final part in plaintext) {
      buffer.add(part);
      while (buffer.length >= kPlaintextChunkSize) {
        final all = buffer.takeBytes();
        final head =
            Uint8List.sublistView(all, 0, kPlaintextChunkSize);
        if (all.length > kPlaintextChunkSize) {
          buffer.add(Uint8List.sublistView(all, kPlaintextChunkSize));
        }
        yield* _emitFrame(chunkIndex++, head);
      }
    }
    final tail = buffer.takeBytes();
    if (tail.isNotEmpty) {
      yield* _emitFrame(chunkIndex++, tail);
    } else if (chunkIndex == 0) {
      yield* _emitFrame(0, Uint8List(0));
    }
  }

  Stream<List<int>> _emitFrame(int chunkIndex, Uint8List plaintext) async* {
    final nonce = _nonceFor(chunkIndex);
    final secretBox = await _gcm.encrypt(
      plaintext,
      secretKey: _key,
      nonce: nonce,
      aad: nonce,
    );
    final cipher = secretBox.cipherText;
    final tag = secretBox.mac.bytes;
    final cipherLen = cipher.length + tag.length;
    final header = Uint8List(_frameHeaderBytes);
    final dv = ByteData.sublistView(header);
    dv.setUint32(0, chunkIndex, Endian.big);
    dv.setUint32(4, cipherLen, Endian.big);
    yield header;
    // Fuse cipher+tag into one buffer so the HTTP layer doesn't fragment
    // them into two tiny TCP writes per chunk.
    final body = Uint8List(cipherLen)
      ..setRange(0, cipher.length, cipher)
      ..setRange(cipher.length, cipherLen, tag);
    yield body;
  }

  /// Inverse of [encrypt]. Decodes the wire stream and emits plaintext
  /// chunks in order. Throws [FormatException] on:
  ///   - chunk index out of order (replay / reorder attack)
  ///   - ciphertext length exceeds [_maxCipherFrameBytes]
  ///   - auth tag mismatch (tampered ciphertext or wrong key)
  ///   - end-of-stream mid-frame (truncation)
  Stream<List<int>> decrypt(Stream<List<int>> wire) async* {
    final buffer = BytesBuilder(copy: false);
    var expectedIndex = 0;
    var awaitingHeader = true;
    var frameIndex = 0;
    var frameBodyLen = 0;
    var framesSeen = 0;

    await for (final part in wire) {
      buffer.add(part);
      while (true) {
        if (awaitingHeader) {
          if (buffer.length < _frameHeaderBytes) break;
          final all = buffer.takeBytes();
          final dv = ByteData.sublistView(all, 0, _frameHeaderBytes);
          frameIndex = dv.getUint32(0, Endian.big);
          frameBodyLen = dv.getUint32(4, Endian.big);
          if (frameBodyLen < _gcmTagBytes ||
              frameBodyLen > _maxCipherFrameBytes) {
            throw FormatException(
                'transfer cipher: bogus ciphertext length $frameBodyLen');
          }
          if (all.length > _frameHeaderBytes) {
            buffer.add(Uint8List.sublistView(all, _frameHeaderBytes));
          }
          awaitingHeader = false;
        }
        if (buffer.length < frameBodyLen) break;
        final all = buffer.takeBytes();
        final body = Uint8List.sublistView(all, 0, frameBodyLen);
        if (all.length > frameBodyLen) {
          buffer.add(Uint8List.sublistView(all, frameBodyLen));
        }

        if (frameIndex != expectedIndex) {
          throw FormatException(
              'transfer cipher: chunk index out of order '
              '(expected $expectedIndex, got $frameIndex)');
        }
        final nonce = _nonceFor(frameIndex);
        final cipher = Uint8List.sublistView(
          body,
          0,
          body.length - _gcmTagBytes,
        );
        final tag = Uint8List.sublistView(
          body,
          body.length - _gcmTagBytes,
        );
        try {
          final plaintext = await _gcm.decrypt(
            SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
            secretKey: _key,
            aad: nonce,
          );
          if (plaintext.isNotEmpty) yield plaintext;
        } on SecretBoxAuthenticationError {
          throw FormatException(
              'transfer cipher: auth tag mismatch on chunk $frameIndex');
        }
        expectedIndex++;
        framesSeen++;
        awaitingHeader = true;
      }
    }
    if (!awaitingHeader || framesSeen == 0) {
      throw const FormatException(
          'transfer cipher: unexpected end of stream');
    }
  }

  Uint8List _nonceFor(int chunkIndex) {
    final n = Uint8List(_nonceBytes);
    n.setRange(0, _transferIdBytes, _transferId);
    final dv = ByteData.sublistView(n, _transferIdBytes);
    dv.setUint32(0, chunkIndex, Endian.big);
    return n;
  }
}
