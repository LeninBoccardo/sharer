import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/tls_key_generator.dart';
import 'package:sharer/data/security/tls_key_material.dart';

void main() {
  group('TlsKeyGenerator', () {
    test('generates a parseable certificate + private key PEM', () {
      final m = TlsKeyGenerator.generate(validityDays: 30);
      expect(m.certificatePem, contains('-----BEGIN CERTIFICATE-----'));
      expect(m.certificatePem, contains('-----END CERTIFICATE-----'));
      expect(m.privateKeyPem, contains('-----BEGIN EC PRIVATE KEY-----'));
      expect(m.privateKeyPem, contains('-----END EC PRIVATE KEY-----'));
    });

    test('SecurityContext accepts the generated cert + key', () {
      // Building a SecurityContext that round-trips through dart:io's
      // BoringSSL is the strongest assertion that the generated PEMs
      // are well-formed — if the encoding is off by a single byte
      // BoringSSL rejects with a noisy error.
      final m = TlsKeyGenerator.generate(validityDays: 30);
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(m.certificatePem.codeUnits)
        ..usePrivateKeyBytes(m.privateKeyPem.codeUnits);
      expect(ctx, isNotNull);
    });

    test('two generations produce different fingerprints', () {
      final a = TlsKeyGenerator.generate(validityDays: 30);
      final b = TlsKeyGenerator.generate(validityDays: 30);
      expect(
        a.certificateFingerprintSha256,
        isNot(equals(b.certificateFingerprintSha256)),
      );
    });

    test('fingerprint matches sha256(DER) hand-derivation', () {
      final m = TlsKeyGenerator.generate(validityDays: 30);
      expect(
        m.certificateFingerprintSha256,
        equals(sha256FingerprintOfDer(m.certificateDer)),
      );
      // Format check: 32 lowercase hex pairs separated by colons.
      expect(
        m.certificateFingerprintSha256,
        matches(RegExp(r'^[0-9a-f]{2}(:[0-9a-f]{2}){31}$')),
      );
    });
  });

  group('derFromPem', () {
    test('throws on missing markers', () {
      expect(
        () => derFromPem('not a pem at all', 'CERTIFICATE'),
        throwsFormatException,
      );
    });

    test('throws on swapped markers', () {
      expect(
        () => derFromPem(
          '-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----',
          'CERTIFICATE',
        ),
        throwsFormatException,
      );
    });
  });
}
