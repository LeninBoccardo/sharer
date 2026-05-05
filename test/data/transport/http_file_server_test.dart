import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/hmac_signer.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/incoming_event.dart';
import 'package:sharer/data/transport/transport_protocol.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

({HttpFileServer server, StreamController<bool> trust, Directory dir}) _setup({
  HmacVerifier? verifier,
}) {
  final dir = Directory.systemTemp.createTempSync('sharer_server_test_');
  final trust = StreamController<bool>.broadcast();
  final server = HttpFileServer(
    downloads: FakeDownloadsLocator(dir),
    isTrusted: trust.stream,
    verifier: verifier,
    port: 0, // ephemeral
  );
  return (server: server, trust: trust, dir: dir);
}

/// Bundles a server with a wired verifier and one paired peer that the
/// test signs every request as. Mirrors slice 4.4's production posture
/// (verifier always set; only signed requests are accepted).
typedef _SignedFixture = ({
  HttpFileServer server,
  StreamController<bool> trust,
  Directory dir,
  PairedDevicesStore paired,
  HmacSigner signer,
  PairedDevice peer,
});

Future<_SignedFixture> _setupSigned({int seed = 7}) async {
  final dir = Directory.systemTemp.createTempSync('sharer_server_test_');
  final trust = StreamController<bool>.broadcast();
  final paired = PairedDevicesStore(FakeSecureKeyValueStore());
  final peer = PairedDevice(
    deviceId: 'sender-1',
    displayName: 'Sender',
    psk: _psk(seed),
    publicKey: _stubPub(seed),
    pairedAt: DateTime.utc(2026, 5, 4),
  );
  await paired.add(peer);
  final server = HttpFileServer(
    downloads: FakeDownloadsLocator(dir),
    isTrusted: trust.stream,
    verifier: HmacVerifier(paired),
    port: 0,
  );
  return (
    server: server,
    trust: trust,
    dir: dir,
    paired: paired,
    signer: HmacSigner(),
    peer: peer,
  );
}

SignedRequestHeaders _signFor({
  required _SignedFixture f,
  required String fileName,
  required int filesize,
}) {
  return f.signer.sign(
    psk: f.peer.psk,
    method: 'POST',
    path: TransportProtocol.uploadPath,
    senderDeviceId: f.peer.deviceId,
    filename: fileName,
    filesize: filesize,
  );
}

Future<HttpClientResponse> _postUpload({
  required int port,
  required String fileName,
  required List<int> body,
  String senderId = 'sender-1',
  String senderName = 'Sender',
  SignedRequestHeaders? signed,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${TransportProtocol.uploadPath}'),
    );
    req.headers.contentLength = body.length;
    req.headers.set(
      TransportProtocol.headerFileName,
      Uri.encodeComponent(fileName),
    );
    req.headers.set(TransportProtocol.headerFileSize, body.length.toString());
    req.headers.set(TransportProtocol.headerDeviceId, senderId);
    req.headers.set(
      TransportProtocol.headerDeviceName,
      Uri.encodeComponent(senderName),
    );
    if (signed != null) {
      req.headers.set(TransportProtocol.headerTimestamp, signed.timestamp);
      req.headers.set(TransportProtocol.headerNonce, signed.nonce);
      req.headers.set(TransportProtocol.headerSignature, signed.signature);
    }
    req.add(body);
    return await req.close();
  } finally {
    client.close();
  }
}

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

/// Stand-in 32-byte publicKey for tests that don't exercise Ed25519 —
/// the upload path verifies HMAC against the PSK, not the public key,
/// so this can be deterministic stub bytes.
Uint8List _stubPub(int seed) => Uint8List.fromList(
    List<int>.generate(32, (i) => (200 + seed + i) & 0xff));

void main() {
  group('HttpFileServer — always-on (slice 5.1)', () {
    test('binds on start regardless of trust state', () async {
      // Slice 5.1 changed the server to bind once on start() and stay
      // bound across trust transitions. Trust only gates the pair
      // routes, not the socket. See architecture.md "Transport —
      // strong rules" #1.
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(false);
      await _settle();

      expect(s.server.isRunning, isTrue,
          reason: 'server stays bound on untrusted networks');
      expect(s.server.boundPort, isNotNull);
    });

    test('stays bound through trust transitions', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();
      final boundPort = s.server.boundPort;
      expect(boundPort, isNotNull);

      s.trust.add(false);
      await _settle();
      expect(s.server.isRunning, isTrue,
          reason: 'untrust must not unbind the socket');
      expect(s.server.boundPort, boundPort,
          reason: 'port stays the same — paired peers cached this IP+port');

      s.trust.add(true);
      await _settle();
      expect(s.server.isRunning, isTrue);
    });

    test('stop() unbinds the socket', () async {
      final s = _setup();
      addTearDown(() async {
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();
      expect(s.server.isRunning, isTrue);

      await s.server.stop();
      expect(s.server.isRunning, isFalse);
    });
  });

  group('HttpFileServer — upload (signed)', () {
    test('writes the body to disk and emits started + completed events',
        () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = f.server.events.listen(events.add);

      await f.server.start();
      f.trust.add(true);
      await _settle();

      const payload = 'hello sharer world';
      final body = utf8.encode(payload);
      final response = await _postUpload(
        port: f.server.boundPort!,
        fileName: 'greeting.txt',
        body: body,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        signed: _signFor(f: f, fileName: 'greeting.txt', filesize: body.length),
      );

      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      final saved = File('${f.dir.path}${Platform.pathSeparator}greeting.txt');
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsString(), payload);

      expect(events.first, isA<IncomingStarted>());
      final started = events.first as IncomingStarted;
      expect(started.fileName, 'greeting.txt');
      expect(started.totalBytes, payload.length);
      expect(started.senderName, f.peer.displayName);

      expect(events.last, isA<IncomingCompleted>());
      expect((events.last as IncomingCompleted).savedPath,
          endsWith('greeting.txt'));

      await eventsSub.cancel();
    });

    test('rejects signed requests with no filename header (400)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      // 400 for missing filename, not 401 — verifier should never see this
      // request because the filename check happens first.
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(
            'http://127.0.0.1:${f.server.boundPort}${TransportProtocol.uploadPath}'));
        req.headers.contentLength = 0;
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });

    test('renames on collision (foo.txt → foo (1).txt)', () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      final port = f.server.boundPort!;
      final firstBody = utf8.encode('first');
      final secondBody = utf8.encode('second');
      await (await _postUpload(
        port: port,
        fileName: 'foo.txt',
        body: firstBody,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        signed: _signFor(f: f, fileName: 'foo.txt', filesize: firstBody.length),
      ))
          .drain<void>();
      await (await _postUpload(
        port: port,
        fileName: 'foo.txt',
        body: secondBody,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        signed:
            _signFor(f: f, fileName: 'foo.txt', filesize: secondBody.length),
      ))
          .drain<void>();
      await _settle();

      final first = File('${f.dir.path}${Platform.pathSeparator}foo.txt');
      final second =
          File('${f.dir.path}${Platform.pathSeparator}foo (1).txt');
      expect(await first.readAsString(), 'first');
      expect(await second.readAsString(), 'second');
    });

    test('sanitizes path-traversal attempts in the filename header',
        () async {
      final f = await _setupSigned();
      addTearDown(() async {
        await f.server.dispose();
        await f.trust.close();
        await f.paired.dispose();
        f.dir.deleteSync(recursive: true);
      });

      await f.server.start();
      f.trust.add(true);
      await _settle();

      final body = utf8.encode('nope');
      final response = await _postUpload(
        port: f.server.boundPort!,
        fileName: '../../etc/passwd',
        body: body,
        senderId: f.peer.deviceId,
        senderName: f.peer.displayName,
        signed:
            _signFor(f: f, fileName: '../../etc/passwd', filesize: body.length),
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      final escaped = Directory(
          '${f.dir.parent.parent.path}${Platform.pathSeparator}etc');
      expect(escaped.existsSync(), isFalse,
          reason: 'should not have written outside the downloads dir');
      expect(f.dir.listSync(), isNotEmpty);
    });
  });

  group('HttpFileServer — HMAC verification', () {
    late FakeSecureKeyValueStore secure;
    late PairedDevicesStore paired;
    late HmacSigner signer;
    late HmacVerifier verifier;

    setUp(() {
      secure = FakeSecureKeyValueStore();
      paired = PairedDevicesStore(secure);
      signer = HmacSigner();
      verifier = HmacVerifier(paired);
    });

    tearDown(() => paired.dispose());

    test('accepts a valid signed request from a paired peer', () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('signed-hello');
      final headers = signer.sign(
        psk: peer.psk,
        method: 'POST',
        path: TransportProtocol.uploadPath,
        senderDeviceId: peer.deviceId,
        filename: 'note.txt',
        filesize: body.length,
      );
      final response = await _postUpload(
        port: s.server.boundPort!,
        fileName: 'note.txt',
        body: body,
        senderId: peer.deviceId,
        senderName: peer.displayName,
        signed: headers,
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
    });

    test('rejects with 401 when signed by a non-paired sender', () async {
      // Verifier knows nobody.
      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('attempt');
      final headers = signer.sign(
        psk: _psk(99),
        method: 'POST',
        path: TransportProtocol.uploadPath,
        senderDeviceId: 'stranger',
        filename: 'note.txt',
        filesize: body.length,
      );
      final response = await _postUpload(
        port: s.server.boundPort!,
        fileName: 'note.txt',
        body: body,
        senderId: 'stranger',
        signed: headers,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
    });

    test('rejects when signed with the wrong PSK', () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final body = utf8.encode('attempt');
      final headers = signer.sign(
        psk: _psk(99), // wrong PSK
        method: 'POST',
        path: TransportProtocol.uploadPath,
        senderDeviceId: peer.deviceId,
        filename: 'note.txt',
        filesize: body.length,
      );
      final response = await _postUpload(
        port: s.server.boundPort!,
        fileName: 'note.txt',
        body: body,
        senderId: peer.deviceId,
        signed: headers,
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
    });

    test('rejects unsigned uploads with 401 even on trusted network '
        '(slice 4.4)', () async {
      // Pairing is the only path to /upload. Trusted-network is no longer
      // an authorization fallback. See docs/v1/security.md §5.
      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      final response = await _postUpload(
        port: s.server.boundPort!,
        fileName: 'unsigned.txt',
        body: utf8.encode('should be rejected'),
      );
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();

      // And nothing landed on disk.
      expect(s.dir.listSync(), isEmpty);
    });

    test('rejects partial signature headers (presence implies completeness)',
        () async {
      final peer = PairedDevice(
        deviceId: 'realme',
        displayName: 'Realme',
        psk: _psk(7),
        publicKey: _stubPub(7),
        pairedAt: DateTime.utc(2026, 5, 4),
      );
      await paired.add(peer);

      final s = _setup(verifier: verifier);
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });
      await s.server.start();
      s.trust.add(true);
      await _settle();

      // Send only timestamp, not the rest.
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(
            'http://127.0.0.1:${s.server.boundPort}${TransportProtocol.uploadPath}'));
        req.headers.contentLength = 4;
        req.headers.set(
            TransportProtocol.headerFileName, Uri.encodeComponent('a.txt'));
        req.headers.set(TransportProtocol.headerFileSize, '4');
        req.headers.set(TransportProtocol.headerDeviceId, peer.deviceId);
        req.headers.set(TransportProtocol.headerTimestamp,
            DateTime.now().millisecondsSinceEpoch.toString());
        req.add(utf8.encode('test'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.unauthorized);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });
  });
}
