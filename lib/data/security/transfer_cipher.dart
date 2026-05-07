import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';

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

/// Plaintext chunk size in bytes. 64 KB — the upper end of the
/// 16–64 KB range docs/v1/security.md §8 calls out.
///
/// Slice 5.3.2.1: bumped from 32 KB after slice 5.x.1 validation
/// surfaced that 111 MB transfers were taking ~15 s. Per-chunk fixed
/// cost (encrypt + 8 B header + 16 B tag + HTTP write) doesn't scale
/// with chunk size, so doubling the chunk halves the chunk count
/// (~3500 → ~1750 for a 111 MB file). Memory footprint is still
/// bounded by exactly one chunk in flight; native AES has no problem
/// with the larger block.
const int kPlaintextChunkSize = 64 * 1024;

/// 4-byte chunkIndex + 4-byte ciphertextLength.
const int _frameHeaderBytes = 8;

/// AES-256-GCM authentication tag length (fixed by the spec).
const int _gcmTagBytes = 16;

/// AES-GCM nonce length (fixed by the spec). transferId(8B) ‖ chunkIndex(4B).
const int _nonceBytes = 12;

/// Cap on a single ciphertext+tag length on the wire. Chosen so a
/// malicious peer can't trick the receiver into allocating a huge buffer
/// from a forged length header. Coupled to [kPlaintextChunkSize] by
/// arithmetic so a future chunk-size bump moves both consts in lockstep.
const int _maxCipherFrameBytes = kPlaintextChunkSize + _gcmTagBytes;

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

/// One framed ciphertext on the wire — header (8B) + body (cipher+tag).
/// Held as a tiny value so the encrypt pipeline can prefetch the next
/// frame as a `Future<_Frame>` while the previous one is being yielded.
class _Frame {
  final Uint8List header;
  final Uint8List body;
  const _Frame(this.header, this.body);
}

/// Queue of byte pieces with O(1) append and zero-copy [takeExact] when
/// the requested span lies inside the head piece. Replaces the previous
/// `BytesBuilder.takeBytes()` + `buffer.add(remainder)` round-trip in
/// [TransferCipher.decrypt], which copied the residual on every chunk
/// when the wire was fragmented.
class _ByteQueue {
  final List<Uint8List> _pieces = <Uint8List>[];
  int _firstOffset = 0;
  int _available = 0;

  void append(List<int> part) {
    final piece = part is Uint8List ? part : Uint8List.fromList(part);
    if (piece.isEmpty) return;
    _pieces.add(piece);
    _available += piece.length;
  }

  /// Returns exactly [n] bytes from the head of the queue, or null if
  /// fewer than [n] bytes are available. Fast path (single piece) is a
  /// `sublistView` — no copy. Slow path (spans pieces) allocates one
  /// fresh `Uint8List(n)` and copies.
  Uint8List? takeExact(int n) {
    if (_available < n) return null;
    final head = _pieces.first;
    final headRemaining = head.length - _firstOffset;
    if (headRemaining >= n) {
      final out = Uint8List.sublistView(head, _firstOffset, _firstOffset + n);
      _firstOffset += n;
      if (_firstOffset == head.length) {
        _pieces.removeAt(0);
        _firstOffset = 0;
      }
      _available -= n;
      return out;
    }
    final out = Uint8List(n);
    var written = 0;
    while (written < n) {
      final src = _pieces.first;
      final srcRemaining = src.length - _firstOffset;
      final need = n - written;
      final take = srcRemaining < need ? srcRemaining : need;
      out.setRange(written, written + take, src, _firstOffset);
      written += take;
      _firstOffset += take;
      if (_firstOffset == src.length) {
        _pieces.removeAt(0);
        _firstOffset = 0;
      }
    }
    _available -= n;
    return out;
  }
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
  ///
  /// Pipelines disk-read with encrypt with HTTP-write: at most one
  /// `_gcm.encrypt` Future is in flight ahead of the consumer, so the
  /// next plaintext part can be read off disk while the previous frame
  /// is still being shipped to TCP. Memory is bounded to one in-flight
  /// chunk plus one snapshot waiting to be encrypted.
  Stream<List<int>> encrypt(Stream<List<int>> plaintext) async* {
    final chunkBuf = Uint8List(kPlaintextChunkSize);
    var chunkOffset = 0;
    var chunkIndex = 0;
    Future<_Frame>? pending;
    try {
      await for (final part in plaintext) {
        var src = 0;
        final partLen = part.length;
        while (src < partLen) {
          final remaining = kPlaintextChunkSize - chunkOffset;
          final available = partLen - src;
          final n = remaining < available ? remaining : available;
          chunkBuf.setRange(chunkOffset, chunkOffset + n, part, src);
          chunkOffset += n;
          src += n;
          if (chunkOffset == kPlaintextChunkSize) {
            // Snapshot — chunkBuf is about to be reused for the next
            // chunk while the previous encrypt may still be running.
            final snap = Uint8List.fromList(chunkBuf);
            chunkOffset = 0;
            // Drain any prefetched frame before starting the next
            // encrypt: this is the backpressure handshake that keeps at
            // most one encrypt in flight.
            if (pending != null) {
              final f = await pending;
              yield f.header;
              yield f.body;
            }
            pending = _encryptFrame(chunkIndex++, snap);
            // Same defensive listener as decrypt — keeps an in-flight
            // encrypt failure from being reported as unhandled before
            // we drain pending.
            pending.catchError((_) => _Frame(Uint8List(0), Uint8List(0)));
          }
        }
      }
      // Drain the prefetched frame (if any) and then any tail.
      if (pending != null) {
        final f = await pending;
        yield f.header;
        yield f.body;
        pending = null;
      }
      if (chunkOffset > 0) {
        final tail = Uint8List.fromList(
            Uint8List.sublistView(chunkBuf, 0, chunkOffset));
        final f = await _encryptFrame(chunkIndex++, tail);
        yield f.header;
        yield f.body;
      } else if (chunkIndex == 0) {
        final f = await _encryptFrame(0, Uint8List(0));
        yield f.header;
        yield f.body;
      }
    } finally {
      // Don't leak an unawaited encrypt on cancel/error.
      if (pending != null) {
        try {
          await pending;
        } catch (_) {/* swallowed — we're already unwinding */}
      }
    }
  }

  Future<_Frame> _encryptFrame(int chunkIndex, Uint8List plaintext) async {
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
    // Fuse cipher+tag into one buffer so the HTTP layer doesn't fragment
    // them into two tiny TCP writes per chunk.
    final body = Uint8List(cipherLen)
      ..setRange(0, cipher.length, cipher)
      ..setRange(cipher.length, cipherLen, tag);
    return _Frame(header, body);
  }

  /// Inverse of [encrypt]. Decodes the wire stream and emits plaintext
  /// chunks in order. Throws [FormatException] on:
  ///   - chunk index out of order (replay / reorder attack)
  ///   - ciphertext length exceeds [_maxCipherFrameBytes]
  ///   - auth tag mismatch (tampered ciphertext or wrong key)
  ///   - end-of-stream mid-frame (truncation)
  ///
  /// Pipelines socket-read with decrypt with disk-write the same way
  /// [encrypt] does: at most one `_gcm.decrypt` Future is in flight
  /// ahead of the consumer.
  Stream<List<int>> decrypt(Stream<List<int>> wire) async* {
    final queue = _ByteQueue();
    var expectedIndex = 0;
    var awaitingHeader = true;
    var frameIndex = 0;
    var frameBodyLen = 0;
    var framesSeen = 0;
    Future<List<int>?>? pending;

    try {
      await for (final part in wire) {
        if (part.isNotEmpty) queue.append(part);
        while (true) {
          if (awaitingHeader) {
            final header = queue.takeExact(_frameHeaderBytes);
            if (header == null) break;
            final dv = ByteData.sublistView(header);
            frameIndex = dv.getUint32(0, Endian.big);
            frameBodyLen = dv.getUint32(4, Endian.big);
            if (frameBodyLen < _gcmTagBytes ||
                frameBodyLen > _maxCipherFrameBytes) {
              throw FormatException(
                  'transfer cipher: bogus ciphertext length $frameBodyLen');
            }
            awaitingHeader = false;
          }
          final body = queue.takeExact(frameBodyLen);
          if (body == null) break;

          if (frameIndex != expectedIndex) {
            throw FormatException(
                'transfer cipher: chunk index out of order '
                '(expected $expectedIndex, got $frameIndex)');
          }
          // Drain prefetched plaintext before kicking off the next
          // decrypt: bounded one-deep pipeline.
          if (pending != null) {
            final pt = await pending;
            if (pt != null && pt.isNotEmpty) yield pt;
          }
          pending = _decryptFrame(frameIndex, body);
          // Attach a no-op error listener so a tag-mismatch / decrypt
          // failure is NOT reported as an unhandled future error during
          // the gap before the drain-block `await pending`. The original
          // Future preserves its error; our later `await` re-throws it.
          pending.catchError((_) => null);
          expectedIndex++;
          framesSeen++;
          awaitingHeader = true;
        }
      }
      if (pending != null) {
        final pt = await pending;
        pending = null;
        if (pt != null && pt.isNotEmpty) yield pt;
      }
      if (!awaitingHeader || framesSeen == 0) {
        throw const FormatException(
            'transfer cipher: unexpected end of stream');
      }
    } finally {
      if (pending != null) {
        try {
          await pending;
        } catch (_) {/* swallowed — already unwinding */}
      }
    }
  }

  Future<List<int>?> _decryptFrame(int frameIndex, Uint8List body) async {
    final nonce = _nonceFor(frameIndex);
    final cipher =
        Uint8List.sublistView(body, 0, body.length - _gcmTagBytes);
    final tag = Uint8List.sublistView(body, body.length - _gcmTagBytes);
    try {
      final plaintext = await _gcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
        secretKey: _key,
        aad: nonce,
      );
      return plaintext;
    } on SecretBoxAuthenticationError {
      throw FormatException(
          'transfer cipher: auth tag mismatch on chunk $frameIndex');
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
