import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:crypto/crypto.dart' as digest;

/// Wraps the device's long-term Ed25519 keypair for identity-bearing
/// signatures. The private key is held in this object only — callers
/// either ask for the public key or hand us bytes to sign. Verification
/// (with someone else's public key) is stateless and exposed as a
/// static method.
///
/// Per slice 4.5, the deviceId becomes the SHA-256 fingerprint of the
/// public key, so the same object also exposes that derivation.
class LongTermSigner {
  static final _alg = Ed25519();

  final SimpleKeyPair _keyPair;
  final List<int> _publicKey;

  LongTermSigner._(this._keyPair, this._publicKey);

  /// Generate a fresh keypair. Use on first launch; the seed must then
  /// be persisted via [extractSeed] so the same identity survives
  /// restarts.
  static Future<LongTermSigner> generate() async {
    final keyPair = await _alg.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    return LongTermSigner._(keyPair, List<int>.unmodifiable(pub.bytes));
  }

  /// Reconstruct a signer from a previously-stored 32-byte seed.
  static Future<LongTermSigner> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed.length',
          'Ed25519 seed must be exactly 32 bytes');
    }
    final keyPair = await _alg.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return LongTermSigner._(keyPair, List<int>.unmodifiable(pub.bytes));
  }

  /// 32-byte raw public key, suitable for embedding in pair offers and
  /// for the receiver to pin alongside the PSK.
  Uint8List get publicKey => Uint8List.fromList(_publicKey);

  /// Public-key fingerprint = first 16 hex chars of SHA-256(publicKey).
  /// This is what we expose as deviceId per slice 4.5's identity model.
  String get deviceIdFingerprint {
    final hash = digest.sha256.convert(_publicKey).bytes;
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(hash[i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// Returns the 32-byte Ed25519 seed. Persist this in secure storage
  /// (only place we ever expose private material).
  Future<Uint8List> extractSeed() async {
    final data = await _keyPair.extract();
    return Uint8List.fromList(data.bytes);
  }

  Future<Uint8List> sign(List<int> message) async {
    final sig = await _alg.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Stateless verification with the peer's published public key. Used
  /// by both the pair-completion handler (to verify the responder's
  /// identity claim) and the responder (to verify the offer's signature
  /// before acting on it).
  static Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    if (publicKey.length != 32) return false;
    final sig = Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    );
    try {
      return await _alg.verify(message, signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Helper that mirrors [deviceIdFingerprint] for any public-key bytes
  /// — used by the receiver to confirm the inviter's claimed deviceId
  /// actually hashes from the public key they sent.
  static String fingerprintOf(List<int> publicKey) {
    final hash = digest.sha256.convert(publicKey).bytes;
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(hash[i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
