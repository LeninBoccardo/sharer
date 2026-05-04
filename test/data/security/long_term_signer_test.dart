import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/long_term_signer.dart';

void main() {
  Uint8List seed(int byte) =>
      Uint8List.fromList(List<int>.filled(32, byte));

  test('fromSeed rejects seeds of the wrong length', () async {
    expect(
      () => LongTermSigner.fromSeed(Uint8List(16)),
      throwsArgumentError,
    );
  });

  test('the same seed reproduces the same keypair', () async {
    final a = await LongTermSigner.fromSeed(seed(1));
    final b = await LongTermSigner.fromSeed(seed(1));
    expect(a.publicKey, equals(b.publicKey));
    expect(a.deviceIdFingerprint, equals(b.deviceIdFingerprint));
  });

  test('different seeds produce different public keys and fingerprints',
      () async {
    final a = await LongTermSigner.fromSeed(seed(1));
    final b = await LongTermSigner.fromSeed(seed(2));
    expect(a.publicKey, isNot(equals(b.publicKey)));
    expect(a.deviceIdFingerprint, isNot(equals(b.deviceIdFingerprint)));
  });

  test('deviceIdFingerprint is 16 lowercase hex chars', () async {
    final s = await LongTermSigner.fromSeed(seed(7));
    expect(s.deviceIdFingerprint, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('extractSeed round-trips through fromSeed', () async {
    final original = await LongTermSigner.generate();
    final seedBytes = await original.extractSeed();
    final reconstructed = await LongTermSigner.fromSeed(seedBytes);
    expect(reconstructed.publicKey, equals(original.publicKey));
  });

  test('sign + verify happy path', () async {
    final s = await LongTermSigner.fromSeed(seed(3));
    final message = Uint8List.fromList([1, 2, 3, 4, 5]);
    final sig = await s.sign(message);
    expect(sig, hasLength(64), reason: 'Ed25519 signatures are 64 bytes');
    final ok = await LongTermSigner.verify(
      message: message,
      signature: sig,
      publicKey: s.publicKey,
    );
    expect(ok, isTrue);
  });

  test('verify rejects tampered messages', () async {
    final s = await LongTermSigner.fromSeed(seed(3));
    final original = Uint8List.fromList([1, 2, 3, 4, 5]);
    final tampered = Uint8List.fromList([1, 2, 3, 4, 6]);
    final sig = await s.sign(original);
    final ok = await LongTermSigner.verify(
      message: tampered,
      signature: sig,
      publicKey: s.publicKey,
    );
    expect(ok, isFalse);
  });

  test('verify rejects when publicKey does not match the signer', () async {
    final signer = await LongTermSigner.fromSeed(seed(3));
    final other = await LongTermSigner.fromSeed(seed(99));
    final message = Uint8List.fromList([1, 2, 3]);
    final sig = await signer.sign(message);
    final ok = await LongTermSigner.verify(
      message: message,
      signature: sig,
      publicKey: other.publicKey,
    );
    expect(ok, isFalse);
  });

  test('verify returns false for malformed publicKey length', () async {
    final ok = await LongTermSigner.verify(
      message: const [1, 2, 3],
      signature: List<int>.filled(64, 0),
      publicKey: const [1, 2, 3], // wrong length
    );
    expect(ok, isFalse);
  });

  test('fingerprintOf matches deviceIdFingerprint', () async {
    final s = await LongTermSigner.fromSeed(seed(11));
    expect(LongTermSigner.fingerprintOf(s.publicKey),
        equals(s.deviceIdFingerprint));
  });
}
