import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/transfer_cipher.dart';

Uint8List _psk(int seed) {
  final r = Random(seed);
  final b = Uint8List(32);
  for (var i = 0; i < b.length; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

Uint8List _bytes(int length, [int seed = 1]) {
  final r = Random(seed);
  final b = Uint8List(length);
  for (var i = 0; i < b.length; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

Future<List<int>> _drain(Stream<List<int>> s) async {
  final out = <int>[];
  await for (final chunk in s) {
    out.addAll(chunk);
  }
  return out;
}

Future<TransferCipher> _cipher({int pskSeed = 7}) async {
  final transferId = newTransferId(Random(42));
  return TransferCipher.derive(psk: _psk(pskSeed), transferId: transferId);
}

void main() {
  group('TransferCipher round-trip', () {
    test('encrypts and decrypts a single small chunk back to identical '
        'plaintext', () async {
      final cipher = await _cipher();
      final plaintext = _bytes(100);
      final wire = await _drain(cipher.encrypt(Stream.value(plaintext)));
      expect(wire.length, encryptedLengthFor(plaintext.length));

      final out = await _drain(cipher.decrypt(Stream.value(wire)));
      expect(out, plaintext);
    });

    test('round-trips an empty payload (one all-zero-plaintext frame)',
        () async {
      final cipher = await _cipher();
      final wire = await _drain(cipher.encrypt(const Stream.empty()));
      expect(wire.length, encryptedLengthFor(0));
      // 8-byte header + 16-byte tag with zero ciphertext.
      expect(wire.length, 24);

      final out = await _drain(cipher.decrypt(Stream.value(wire)));
      expect(out, isEmpty);
    });

    test('round-trips a payload spanning many chunks (3.5 chunks)', () async {
      final cipher = await _cipher();
      final plaintext = _bytes(kPlaintextChunkSize * 3 + 7777, 99);
      final wire = await _drain(cipher.encrypt(Stream.value(plaintext)));
      expect(wire.length, encryptedLengthFor(plaintext.length));

      // Decrypt with an arbitrary network-fragmentation pattern: feed
      // bytes 1 by 1 to make sure the streaming parser handles the
      // worst case.
      final fragmented =
          Stream<List<int>>.fromIterable(wire.map((b) => [b]));
      final out = await _drain(cipher.decrypt(fragmented));
      expect(out, plaintext);
    });

    test('round-trips a payload exactly equal to chunk size', () async {
      final cipher = await _cipher();
      final plaintext = _bytes(kPlaintextChunkSize, 11);
      final wire = await _drain(cipher.encrypt(Stream.value(plaintext)));
      // One chunk, not two.
      expect(wire.length, kPlaintextChunkSize + 24);

      final out = await _drain(cipher.decrypt(Stream.value(wire)));
      expect(out, plaintext);
    });

    test('producer that emits weirdly-sized chunks still re-chunks to '
        'fixed plaintext frames', () async {
      final cipher = await _cipher();
      final plaintext = _bytes(kPlaintextChunkSize * 2 + 333, 13);
      final pieces = [
        plaintext.sublist(0, 5),
        plaintext.sublist(5, 5 + kPlaintextChunkSize),
        plaintext.sublist(5 + kPlaintextChunkSize),
      ];
      final wire = await _drain(
        cipher.encrypt(Stream<List<int>>.fromIterable(pieces)),
      );
      expect(wire.length, encryptedLengthFor(plaintext.length));

      final out = await _drain(cipher.decrypt(Stream.value(wire)));
      expect(out, plaintext);
    });
  });

  group('TransferCipher rejection paths', () {
    test('decrypting with the wrong PSK throws on the first auth tag',
        () async {
      final senderTransferId = newTransferId(Random(42));
      final senderCipher = await TransferCipher.derive(
        psk: _psk(1),
        transferId: senderTransferId,
      );
      final attackerCipher = await TransferCipher.derive(
        psk: _psk(2), // different PSK
        transferId: senderTransferId,
      );
      final wire =
          await _drain(senderCipher.encrypt(Stream.value(_bytes(64))));

      expect(
        () => _drain(attackerCipher.decrypt(Stream.value(wire))),
        throwsA(isA<FormatException>()),
      );
    });

    test('flipping a single ciphertext byte trips the auth tag', () async {
      final cipher = await _cipher();
      final wire = await _drain(cipher.encrypt(Stream.value(_bytes(64))));
      // Header is 8 bytes, then ciphertext+tag. Flip a bit in the
      // middle of the ciphertext (well before the tag).
      wire[16] ^= 0x01;

      expect(
        () => _drain(cipher.decrypt(Stream.value(wire))),
        throwsA(isA<FormatException>()),
      );
    });

    test('truncating the wire stream mid-frame is reported, not silently '
        'accepted', () async {
      final cipher = await _cipher();
      final wire = await _drain(cipher.encrypt(Stream.value(_bytes(64))));
      // Drop the last byte of the auth tag.
      final truncated = wire.sublist(0, wire.length - 1);

      expect(
        () => _drain(cipher.decrypt(Stream.value(truncated))),
        throwsA(isA<FormatException>()),
      );
    });

    test('forged length header beyond the cap is rejected before any '
        'allocation', () async {
      final cipher = await _cipher();
      final forged = Uint8List(8);
      // chunkIndex = 0
      // ciphertextLength = 10 MB, well above the cap
      final dv = ByteData.sublistView(forged);
      dv.setUint32(0, 0);
      dv.setUint32(4, 10 * 1024 * 1024);

      expect(
        () => _drain(cipher.decrypt(Stream.value(forged))),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('encryptedLengthFor', () {
    test('zero plaintext: header + tag only', () {
      expect(encryptedLengthFor(0), 24);
    });

    test('one chunk worth of plaintext: 24 bytes overhead', () {
      expect(encryptedLengthFor(kPlaintextChunkSize),
          kPlaintextChunkSize + 24);
    });

    test('two chunks: 48 bytes overhead', () {
      expect(encryptedLengthFor(kPlaintextChunkSize + 1),
          kPlaintextChunkSize + 1 + 48);
    });
  });

  test('newTransferId is always exactly 8 bytes', () {
    expect(newTransferId(Random(1)).length, 8);
    expect(newTransferId(Random(99)).length, 8);
  });
}
