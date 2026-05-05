import 'package:basic_utils/basic_utils.dart';

import 'tls_key_material.dart';

/// Generates a fresh self-signed TLS keypair + certificate for the
/// device. ECDSA on P-256 (prime256v1) — smaller than RSA-2048, faster
/// handshake, and well-supported in dart:io's BoringSSL backend.
///
/// The cert is issued to `CN=sharer-device`. Hostname is meaningless in
/// our model — clients don't validate the SAN, they pin the cert
/// fingerprint exchanged at pair time. Validity is set absurdly long
/// (100 years) because there is no rotation story in v1; if the cert
/// were to expire, transfers would silently break.
///
/// Returns PEM-encoded cert + key. Caller is responsible for persistence
/// (cert PEM in regular prefs is fine; the private key MUST go in
/// secure storage).
abstract final class TlsKeyGenerator {
  /// Subject DN attributes. Fixed to a single CN so the encoded length
  /// stays small (the QR payload is bounded).
  static const Map<String, String> _subject = {
    'CN': 'sharer-device',
  };

  static const int _defaultDays = 365 * 100;

  static TlsKeyMaterial generate({int validityDays = _defaultDays}) {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(_subject, privateKey, publicKey);
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      validityDays,
    );
    final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(privateKey);
    return TlsKeyMaterial(certificatePem: certPem, privateKeyPem: keyPem);
  }
}
