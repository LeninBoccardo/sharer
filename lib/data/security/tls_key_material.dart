import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Self-signed TLS key material for the local device's HTTP server
/// (slice 5.1). Generated once on first launch, persisted in
/// flutter_secure_storage. The same key/cert pair survives across
/// network changes — only a "factory reset" regenerates them, which
/// also forces re-pairing because the fingerprint changes.
class TlsKeyMaterial {
  /// PEM-encoded certificate (`-----BEGIN CERTIFICATE-----` ... ).
  final String certificatePem;

  /// PEM-encoded private key (`-----BEGIN EC PRIVATE KEY-----` ...).
  /// Lives in [SecureKeyValueStore] only — never in shared_preferences,
  /// never in the QR payload.
  final String privateKeyPem;

  TlsKeyMaterial({
    required this.certificatePem,
    required this.privateKeyPem,
  });

  /// SHA-256 fingerprint of the DER-encoded certificate, formatted as
  /// 32 lowercase hex pairs separated by colons. Standard X.509 cert
  /// fingerprint format — what every other TLS tool calls a
  /// "thumbprint." Pinned per-paired-peer; clients reject any cert
  /// whose fingerprint doesn't match for the target deviceId.
  String get certificateFingerprintSha256 =>
      sha256FingerprintOfPem(certificatePem);

  /// Raw DER bytes of the certificate. Used by clients to compute the
  /// hash for pinning checks against [TlsKeyMaterial.certificateFingerprintSha256].
  Uint8List get certificateDer => derFromPem(certificatePem, 'CERTIFICATE');
}

/// Strips the PEM armour and base64-decodes the body. Throws
/// [FormatException] on a malformed PEM.
Uint8List derFromPem(String pem, String label) {
  final begin = '-----BEGIN $label-----';
  final end = '-----END $label-----';
  final start = pem.indexOf(begin);
  final stop = pem.indexOf(end);
  if (start < 0 || stop < 0 || stop <= start) {
    throw FormatException('Malformed PEM (missing $label markers)');
  }
  final body = pem
      .substring(start + begin.length, stop)
      .replaceAll(RegExp(r'\s+'), '');
  return Uint8List.fromList(base64Decode(body));
}

/// SHA-256 fingerprint of the DER content of a CERTIFICATE PEM block,
/// formatted as `aa:bb:cc:...`.
String sha256FingerprintOfPem(String certificatePem) {
  final der = derFromPem(certificatePem, 'CERTIFICATE');
  return sha256FingerprintOfDer(der);
}

/// SHA-256 fingerprint of raw DER cert bytes, in the standard
/// `aa:bb:cc:...` colon-separated lowercase-hex form.
String sha256FingerprintOfDer(List<int> der) {
  final digest = sha256.convert(der).bytes;
  final buf = StringBuffer();
  for (var i = 0; i < digest.length; i++) {
    if (i > 0) buf.write(':');
    buf.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
