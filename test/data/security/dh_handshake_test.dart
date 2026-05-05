import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/dh_handshake.dart';

void main() {
  group('EphemeralX25519KeyPair', () {
    test('generate produces a 32-byte public key', () async {
      final kp = await EphemeralX25519KeyPair.generate();
      expect(kp.publicKey, hasLength(32));
    });

    test('two generations produce distinct keys', () async {
      final a = await EphemeralX25519KeyPair.generate();
      final b = await EphemeralX25519KeyPair.generate();
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });
  });

  group('derivePairPsk', () {
    test('both sides arrive at the same 32-byte PSK', () async {
      final initiator = await EphemeralX25519KeyPair.generate();
      final responder = await EphemeralX25519KeyPair.generate();

      final pskInitiatorSide = await derivePairPsk(
        myEphemeralKeyPair: initiator.keyPair,
        peerEphemeralPublicKey: responder.publicKey,
        initiatorEphemeralPublicKey: initiator.publicKey,
        responderEphemeralPublicKey: responder.publicKey,
      );
      final pskResponderSide = await derivePairPsk(
        myEphemeralKeyPair: responder.keyPair,
        peerEphemeralPublicKey: initiator.publicKey,
        initiatorEphemeralPublicKey: initiator.publicKey,
        responderEphemeralPublicKey: responder.publicKey,
      );
      expect(pskInitiatorSide, hasLength(32));
      expect(pskInitiatorSide, equals(pskResponderSide));
    });

    test('a third party with different ephemerals derives a different PSK',
        () async {
      // Simulate a MITM that ran two separate exchanges — A↔M and M↔B.
      // M ends up with two PSKs, neither of which equals the one A and
      // B would have derived if they spoke directly. The fingerprint
      // therefore cannot match on both screens.
      final a = await EphemeralX25519KeyPair.generate();
      final m1 = await EphemeralX25519KeyPair.generate();
      final m2 = await EphemeralX25519KeyPair.generate();
      final b = await EphemeralX25519KeyPair.generate();

      // PSK A would compute if it had spoken directly to B.
      final pskAB = await derivePairPsk(
        myEphemeralKeyPair: a.keyPair,
        peerEphemeralPublicKey: b.publicKey,
        initiatorEphemeralPublicKey: a.publicKey,
        responderEphemeralPublicKey: b.publicKey,
      );

      // PSK A actually computes when it sees M's public key as the
      // "responder".
      final pskAM = await derivePairPsk(
        myEphemeralKeyPair: a.keyPair,
        peerEphemeralPublicKey: m1.publicKey,
        initiatorEphemeralPublicKey: a.publicKey,
        responderEphemeralPublicKey: m1.publicKey,
      );

      // PSK B actually computes when it sees M's public key as the
      // "initiator".
      final pskBM = await derivePairPsk(
        myEphemeralKeyPair: b.keyPair,
        peerEphemeralPublicKey: m2.publicKey,
        initiatorEphemeralPublicKey: m2.publicKey,
        responderEphemeralPublicKey: b.publicKey,
      );

      expect(pskAM, isNot(equals(pskAB)));
      expect(pskBM, isNot(equals(pskAB)));
      expect(pskAM, isNot(equals(pskBM)));
      expect(pairFingerprint(pskAM), isNot(equals(pairFingerprint(pskBM))));
    });

    test('rejects peer keys of the wrong length', () async {
      final me = await EphemeralX25519KeyPair.generate();
      expect(
        () => derivePairPsk(
          myEphemeralKeyPair: me.keyPair,
          peerEphemeralPublicKey: Uint8List(16),
          initiatorEphemeralPublicKey: me.publicKey,
          responderEphemeralPublicKey: Uint8List(16),
        ),
        throwsArgumentError,
      );
    });
  });

  group('pairFingerprint', () {
    test('produces 6 decimal digits, zero-padded', () {
      // Hand-crafted PSK whose HMAC-SHA256("verify", PSK) starts with
      // bytes whose top 32 bits mod 10^6 ≠ 0, so we can match on the
      // shape rather than on a brittle constant.
      final psk = Uint8List.fromList(List<int>.filled(32, 0xab));
      final fp = pairFingerprint(psk);
      expect(fp, matches(RegExp(r'^\d{6}$')));
    });

    test('same PSK → same fingerprint, different PSK → different '
        'fingerprint (almost surely)', () {
      final fp1 = pairFingerprint(Uint8List.fromList(List<int>.filled(32, 1)));
      final fp1b = pairFingerprint(Uint8List.fromList(List<int>.filled(32, 1)));
      final fp2 = pairFingerprint(Uint8List.fromList(List<int>.filled(32, 2)));
      expect(fp1, equals(fp1b));
      // The collision probability for two random PSKs is 1 in 10^6;
      // for these two specific PSKs the result is deterministic so
      // this assertion is safe.
      expect(fp1, isNot(equals(fp2)));
    });

    test('matches the by-hand HMAC-then-mod-10^6 derivation', () {
      final psk = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final mac = Hmac(sha256, psk).convert(utf8.encode('verify'));
      final b = mac.bytes;
      final n = ((b[0] & 0xff) << 24) |
          ((b[1] & 0xff) << 16) |
          ((b[2] & 0xff) << 8) |
          (b[3] & 0xff);
      final expected =
          (n.toUnsigned(32) % 1000000).toString().padLeft(6, '0');
      expect(pairFingerprint(psk), equals(expected));
    });
  });

  group('formatFingerprint', () {
    test('renders as "AB CD EF"', () {
      expect(formatFingerprint('123456'), '12 34 56');
    });

    test('non-6-digit inputs pass through untouched', () {
      expect(formatFingerprint('12'), '12');
    });
  });
}
