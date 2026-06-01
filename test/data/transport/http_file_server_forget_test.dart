import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/security/forget_service.dart';
import 'package:sharer/data/security/hmac_signer.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/peer_forget_signer.dart';
import 'package:sharer/data/security/transfer_cipher.dart';
import 'package:sharer/data/storage/peer_cache_store.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/transport_protocol.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

Uint8List _stubPub(int seed) => Uint8List.fromList(
    List<int>.generate(32, (i) => (200 + seed + i) & 0xff));

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<HttpClientResponse> _postPeerForgotYou({
  required int port,
  required String senderId,
  required String signatureBase64,
}) async {
  final body = jsonEncode({
    'senderId': senderId,
    'signature': signatureBase64,
  });
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(
        'http://127.0.0.1:$port${TransportProtocol.peerForgotYouPath}'));
    final encoded = utf8.encode(body);
    req.headers.contentLength = encoded.length;
    req.headers.contentType = ContentType.json;
    req.add(encoded);
    return await req.close();
  } finally {
    client.close();
  }
}

/// Posts [body] to /peer-forgot-you and asserts the server REFUSED an
/// oversized body. Rejecting mid-stream can surface to the client as
/// either a 413 response or a connection reset (the server stops reading
/// and responds/closes early) — both are valid refusals. The caller
/// additionally asserts the security contract (no state change).
Future<void> _expectOversizedRefused(
  int port,
  List<int> body, {
  required bool chunked,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(
        'http://127.0.0.1:$port${TransportProtocol.peerForgotYouPath}'));
    if (chunked) {
      req.headers.chunkedTransferEncoding = true; // no content-length
    } else {
      req.headers.contentLength = body.length; // honest, over the cap
    }
    req.headers.contentType = ContentType.json;
    req.add(body);
    final resp = await req.close();
    expect(resp.statusCode, HttpStatus.requestEntityTooLarge,
        reason: 'if the server responded at all, it must be 413');
    await resp.drain<void>();
  } on SocketException {
    // Server reset the connection mid-write — a valid refusal.
  } on HttpException {
    // e.g. "Connection closed before full header" — also a refusal.
  } finally {
    client.close();
  }
}

Future<HttpClientResponse> _postSignedUpload({
  required int port,
  required HmacSigner signer,
  required Uint8List psk,
  required String senderId,
  required String fileName,
  required List<int> body,
}) async {
  final transferId = newTransferId(Random(31));
  final transferIdB64 = base64Encode(transferId);
  final cipher = await TransferCipher.derive(psk: psk, transferId: transferId);
  final encrypted = <int>[];
  await for (final part in cipher.encrypt(Stream.value(body))) {
    encrypted.addAll(part);
  }
  final signed = signer.sign(
    psk: psk,
    method: 'POST',
    path: TransportProtocol.uploadPath,
    senderDeviceId: senderId,
    filename: fileName,
    filesize: body.length,
    transferId: transferIdB64,
  );
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(
        'http://127.0.0.1:$port${TransportProtocol.uploadPath}'));
    req.headers.contentLength = encrypted.length;
    req.headers.set(
        TransportProtocol.headerFileName, Uri.encodeComponent(fileName));
    req.headers.set(TransportProtocol.headerFileSize, body.length.toString());
    req.headers.set(TransportProtocol.headerDeviceId, senderId);
    req.headers
        .set(TransportProtocol.headerDeviceName, Uri.encodeComponent('Sender'));
    req.headers.set(TransportProtocol.headerTransferId, transferIdB64);
    req.headers.set(TransportProtocol.headerTimestamp, signed.timestamp);
    req.headers.set(TransportProtocol.headerNonce, signed.nonce);
    req.headers.set(TransportProtocol.headerSignature, signed.signature);
    req.add(encrypted);
    return await req.close();
  } finally {
    client.close();
  }
}

void main() {
  late Directory tmpDir;
  late StreamController<bool> trust;
  late PairedDevicesStore paired;
  late PeerCacheStore cache;
  late HmacVerifier verifier;
  late StaticIdentityRepo identity;
  late ForgetService forget;
  late HttpFileServer server;
  late HmacSigner signer;
  late PairedDevice peer;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_forget_test_');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    cache = PeerCacheStore(prefs);
    paired = PairedDevicesStore(FakeSecureKeyValueStore());
    peer = PairedDevice(
      deviceId: 'realme',
      displayName: 'Realme',
      psk: _psk(7),
      publicKey: _stubPub(7),
      certFingerprint: 'aa:bb:cc',
      pairedAt: DateTime.utc(2026, 5, 4),
    );
    await paired.add(peer);
    verifier = HmacVerifier(paired);
    identity = await StaticIdentityRepo.create(seed: 9);
    forget = ForgetService(
      pairedRepo: paired,
      peerCache: cache,
      client: PairInviteClient(HttpClient()), // never actually used here
      identityRepo: identity,
    );
    trust = StreamController<bool>.broadcast();
    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      verifier: verifier,
      peerCache: cache,
      forget: forget,
      port: 0,
    );
    signer = HmacSigner();
    await server.start();
    trust.add(true);
    await _settle();
  });

  tearDown(() async {
    await server.dispose();
    await trust.close();
    await forget.dispose();
    await paired.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  group('slice 5.4 — source IP capture', () {
    test('an HMAC-verified upload caches the sender source IP under '
        'their deviceId', () async {
      final response = await _postSignedUpload(
        port: server.boundPort!,
        signer: signer,
        psk: peer.psk,
        senderId: peer.deviceId,
        fileName: 'a.txt',
        body: utf8.encode('hello'),
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      final cached = await cache.getById(peer.deviceId);
      expect(cached, isNotNull);
      expect(cached!.host, '127.0.0.1');
      expect(cached.port, TransportProtocol.defaultPort);
    });
  });

  group('slice 5.4 — POST /peer-forgot-you', () {
    test('a valid signed POST removes the local PairedDevice and emits '
        'a proactive ForgetEvent', () async {
      final received = <ForgetEvent>[];
      final sub = forget.events.listen(received.add);

      final sig = signPeerForgotYou(psk: peer.psk, senderId: peer.deviceId);
      final response = await _postPeerForgotYou(
        port: server.boundPort!,
        senderId: peer.deviceId,
        signatureBase64: sig,
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      expect(await paired.get(peer.deviceId), isNull);
      expect(received, hasLength(1));
      expect(received.first.cause, ForgetCause.proactive);
      expect(received.first.peerName, 'Realme');

      await sub.cancel();
    });

    test('a POST signed by an unknown device is treated as no-op '
        '(idempotent — they already aren\'t paired)', () async {
      final received = <ForgetEvent>[];
      final sub = forget.events.listen(received.add);

      final sig = signPeerForgotYou(psk: _psk(99), senderId: 'stranger');
      final response = await _postPeerForgotYou(
        port: server.boundPort!,
        senderId: 'stranger',
        signatureBase64: sig,
      );
      expect(response.statusCode, HttpStatus.ok); // 200 not 401
      await response.drain<void>();
      await _settle();

      expect(await paired.get(peer.deviceId), isNotNull,
          reason: 'paired peer is untouched');
      expect(received, isEmpty);
      await sub.cancel();
    });

    test('a POST with a valid senderId but bad signature returns 401 + '
        'no removal', () async {
      final received = <ForgetEvent>[];
      final sub = forget.events.listen(received.add);

      // Sign with the wrong PSK.
      final sig =
          signPeerForgotYou(psk: _psk(99), senderId: peer.deviceId);
      final response = await _postPeerForgotYou(
        port: server.boundPort!,
        senderId: peer.deviceId,
        signatureBase64: sig,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
      await _settle();

      expect(await paired.get(peer.deviceId), isNotNull);
      expect(received, isEmpty);
      await sub.cancel();
    });

    test('a malformed JSON body returns 400', () async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('http://127.0.0.1:'
            '${server.boundPort}${TransportProtocol.peerForgotYouPath}'));
        req.headers.contentLength = 4;
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode('not!'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });

    test('an oversized body (declared content-length) is refused without '
        'touching the pair (audit #8 declared-length guard)', () async {
      // > 64 KB cap; must be refused before any decode/HMAC/state work.
      final big = jsonEncode({
        'senderId': peer.deviceId,
        'signature': 'A' * (200 * 1024),
      });
      await _expectOversizedRefused(
        server.boundPort!,
        utf8.encode(big),
        chunked: false,
      );
      await _settle();
      expect(await paired.get(peer.deviceId), isNotNull,
          reason: 'oversized body must not mutate state');
    });

    test('an oversized chunked body (no content-length) is refused '
        '(audit #8 stream guard)', () async {
      // 128 KB across chunks, no content-length to lean on.
      final body = utf8.encode('B' * (128 * 1024));
      await _expectOversizedRefused(server.boundPort!, body, chunked: true);
      await _settle();
      expect(await paired.get(peer.deviceId), isNotNull);
    });

    test('a successful POST also wipes any cached entry — the peer is '
        'gone, the cached IP is no longer useful', () async {
      // Pre-populate a cached entry so we can prove it gets removed
      // alongside the paired entry on a successful peer-forgot-you.
      await cache.cacheAddress(
        deviceId: peer.deviceId,
        host: '192.168.68.56',
        port: 8080,
      );
      expect(await cache.getById(peer.deviceId), isNotNull);

      final sig = signPeerForgotYou(psk: peer.psk, senderId: peer.deviceId);
      final response = await _postPeerForgotYou(
        port: server.boundPort!,
        senderId: peer.deviceId,
        signatureBase64: sig,
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      expect(await cache.getById(peer.deviceId), isNull);
    });
  });
}
