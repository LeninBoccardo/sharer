import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:crypto/crypto.dart' as digest;

/// Crypto primitives for the slice 4.6 LAN pair-invite handshake:
///
///   1. X25519 ephemeral keypair per side, lifetime = one pair attempt.
///   2. HKDF-SHA256 derives the long-term per-pair PSK from the X25519
///      shared secret. The PSK never travels on the wire.
///   3. A 6-digit fingerprint over the PSK lets both users visually
///      confirm they reached the same shared secret. A LAN MITM that
///      intercepts both halves ends up with two different PSKs (and
///      therefore two different fingerprints), so the digits won't match.
///
/// All material here is in-process only. Persisting any of it (the
/// ephemeral private key especially) would weaken the model — the whole
/// point of fresh ephemerals per attempt is forward secrecy on the
/// long-term identity if the device is later compromised.

class EphemeralX25519KeyPair {
  EphemeralX25519KeyPair._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  static Future<EphemeralX25519KeyPair> generate() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    return EphemeralX25519KeyPair._(
      kp,
      Uint8List.fromList(pub.bytes),
    );
  }
}

/// Derive the per-pair PSK on either side of the handshake. Both sides
/// must pass the same [initiatorPublicKey] / [responderPublicKey] so the
/// HKDF salt is identical end-to-end.
Future<Uint8List> derivePairPsk({
  required SimpleKeyPair myEphemeralKeyPair,
  required Uint8List peerEphemeralPublicKey,
  required Uint8List initiatorEphemeralPublicKey,
  required Uint8List responderEphemeralPublicKey,
}) async {
  if (peerEphemeralPublicKey.length != 32) {
    throw ArgumentError.value(peerEphemeralPublicKey.length,
        'peerEphemeralPublicKey.length', 'X25519 public key must be 32 bytes');
  }
  final shared = await X25519().sharedSecretKey(
    keyPair: myEphemeralKeyPair,
    remotePublicKey: SimplePublicKey(
      peerEphemeralPublicKey,
      type: KeyPairType.x25519,
    ),
  );
  final salt = Uint8List(64)
    ..setRange(0, 32, initiatorEphemeralPublicKey)
    ..setRange(32, 64, responderEphemeralPublicKey);
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final psk = await hkdf.deriveKey(
    secretKey: shared,
    nonce: salt,
    info: utf8.encode('sharer-pair-v1'),
  );
  return Uint8List.fromList(await psk.extractBytes());
}

/// Six-digit decimal fingerprint over the derived PSK. The same bytes
/// produce the same number on every device, so when both screens show
/// the same digits the user knows the X25519 exchange wasn't intercepted.
String pairFingerprint(Uint8List psk) {
  final mac = digest.Hmac(digest.sha256, psk).convert(utf8.encode('verify'));
  final b = mac.bytes;
  // First 32 bits, big-endian, modulo 10^6 → 6 zero-padded digits.
  final n = ((b[0] & 0xff) << 24) |
      ((b[1] & 0xff) << 16) |
      ((b[2] & 0xff) << 8) |
      (b[3] & 0xff);
  final digits = n.toUnsigned(32) % 1000000;
  return digits.toString().padLeft(6, '0');
}

/// Pretty-printed form of [pairFingerprint] for the modal — `12 34 56`,
/// monospace, easier to compare across the room.
String formatFingerprint(String fingerprint) {
  if (fingerprint.length != 6) return fingerprint;
  return '${fingerprint.substring(0, 2)} '
      '${fingerprint.substring(2, 4)} '
      '${fingerprint.substring(4, 6)}';
}
