import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/pinning_http_client.dart';
import 'package:sharer/data/security/tls_key_generator.dart';

/// Boots a tiny HTTPS echo server with the given cert and returns the
/// bound port. Caller is responsible for closing the server.
Future<HttpServer> _bootEchoServer({
  required String certPem,
  required String keyPem,
}) async {
  final ctx = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(certPem.codeUnits)
    ..usePrivateKeyBytes(keyPem.codeUnits);
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
  );
  // Drain every request and reply 200 OK. The test just wants to know
  // whether the TLS handshake succeeded — body content is irrelevant.
  unawaited(() async {
    await for (final req in server) {
      await req.drain<void>();
      req.response
        ..statusCode = 200
        ..write('ok');
      await req.response.close();
    }
  }());
  return server;
}

void main() {
  // One real cert, reused across tests — keygen takes ~50ms so amortising
  // is worth it.
  late final certA = TlsKeyGenerator.generate(validityDays: 30);
  late final certB = TlsKeyGenerator.generate(validityDays: 30);

  group('buildPinningHttpClient — pin mode', () {
    test('accepts a request when the cert fingerprint matches', () async {
      final server = await _bootEchoServer(
        certPem: certA.certificatePem,
        keyPem: certA.privateKeyPem,
      );
      addTearDown(() async => server.close(force: true));

      final client = buildPinningHttpClient(
        expectedFingerprint: certA.certificateFingerprintSha256,
      );
      addTearDown(() => client.close(force: true));

      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/anything'),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      await resp.drain<void>();
    });

    test('rejects a request when the cert fingerprint does not match',
        () async {
      // Server presents certA; client expects certB.
      final server = await _bootEchoServer(
        certPem: certA.certificatePem,
        keyPem: certA.privateKeyPem,
      );
      addTearDown(() async => server.close(force: true));

      final client = buildPinningHttpClient(
        expectedFingerprint: certB.certificateFingerprintSha256,
      );
      addTearDown(() => client.close(force: true));

      expect(
        () async {
          final req = await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/anything'),
          );
          await req.close();
        },
        throwsA(isA<HandshakeException>()),
      );
    });

    test('fingerprint comparison is case-insensitive', () async {
      final server = await _bootEchoServer(
        certPem: certA.certificatePem,
        keyPem: certA.privateKeyPem,
      );
      addTearDown(() async => server.close(force: true));

      final client = buildPinningHttpClient(
        expectedFingerprint:
            certA.certificateFingerprintSha256.toUpperCase(),
      );
      addTearDown(() => client.close(force: true));

      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      await resp.drain<void>();
    });
  });

  group('buildPinningHttpClient — TOFU mode', () {
    test('accepts any cert and reports its fingerprint to the sink',
        () async {
      final server = await _bootEchoServer(
        certPem: certA.certificatePem,
        keyPem: certA.privateKeyPem,
      );
      addTearDown(() async => server.close(force: true));

      final captured = <String>[];
      final client = buildPinningHttpClient(
        tofuSink: (_, _, fp) => captured.add(fp),
      );
      addTearDown(() => client.close(force: true));

      final req = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      await resp.drain<void>();

      // The bad-certificate callback may fire more than once for a
      // single handshake (depending on the chain validation pass);
      // we just care that every capture is the same and matches the
      // server's actual cert.
      expect(captured, isNotEmpty);
      expect(
        captured.toSet(),
        {certA.certificateFingerprintSha256},
      );
    });
  });

  test('asserts when constructed without pin or TOFU sink', () {
    expect(
      () => buildPinningHttpClient(),
      throwsA(isA<AssertionError>()),
    );
  });

  // Silence the unused field warning when the file is loaded without
  // running every test variant.
  test('certA / certB warmup', () {
    expect(certA.certificateFingerprintSha256, isNotEmpty);
    expect(certB.certificateFingerprintSha256, isNotEmpty);
    final dummyBody = utf8.encode('warmup');
    expect(dummyBody, isNotEmpty);
  });
}
