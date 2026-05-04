import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/incoming_event.dart';
import 'package:sharer/data/transport/transport_protocol.dart';

import '../../fakes/fake_downloads_locator.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

({HttpFileServer server, StreamController<bool> trust, Directory dir}) _setup() {
  final dir = Directory.systemTemp.createTempSync('sharer_server_test_');
  final trust = StreamController<bool>.broadcast();
  final server = HttpFileServer(
    downloads: FakeDownloadsLocator(dir),
    isTrusted: trust.stream,
    port: 0, // ephemeral
  );
  return (server: server, trust: trust, dir: dir);
}

Future<HttpClientResponse> _postUpload({
  required int port,
  required String fileName,
  required List<int> body,
  String senderId = 'sender-1',
  String senderName = 'Sender',
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
    req.add(body);
    return await req.close();
  } finally {
    client.close();
  }
}

void main() {
  group('HttpFileServer — trust gating', () {
    test('does not bind on untrusted', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(false);
      await _settle();

      expect(s.server.isRunning, isFalse);
      expect(s.server.boundPort, isNull);
    });

    test('binds on trusted, unbinds on untrusted', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();
      expect(s.server.isRunning, isTrue);
      expect(s.server.boundPort, isNotNull);

      s.trust.add(false);
      await _settle();
      expect(s.server.isRunning, isFalse);
    });

    test('rapid trust → untrust → trust converges to bound', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      s.trust.add(false);
      s.trust.add(true);
      await _settle();

      expect(s.server.isRunning, isTrue);
    });

    test('stop() unbinds regardless of trust', () async {
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

  group('HttpFileServer — upload', () {
    test('writes the body to disk and emits started + completed events',
        () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      final events = <IncomingEvent>[];
      final eventsSub = s.server.events.listen(events.add);

      await s.server.start();
      s.trust.add(true);
      await _settle();

      const payload = 'hello sharer world';
      final response = await _postUpload(
        port: s.server.boundPort!,
        fileName: 'greeting.txt',
        body: utf8.encode(payload),
      );

      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();

      // Allow the server to drain its event controller.
      await _settle();

      // File on disk matches what we sent.
      final saved = File('${s.dir.path}${Platform.pathSeparator}greeting.txt');
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsString(), payload);

      // Events arrived in the right shape.
      expect(events.first, isA<IncomingStarted>());
      final started = events.first as IncomingStarted;
      expect(started.fileName, 'greeting.txt');
      expect(started.totalBytes, payload.length);
      expect(started.senderName, 'Sender');

      expect(events.last, isA<IncomingCompleted>());
      expect(
        (events.last as IncomingCompleted).savedPath,
        endsWith('greeting.txt'),
      );

      await eventsSub.cancel();
    });

    test('rejects requests with no filename header', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();

      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(
            'http://127.0.0.1:${s.server.boundPort}${TransportProtocol.uploadPath}'));
        req.headers.contentLength = 0;
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain<void>();
      } finally {
        client.close();
      }
    });

    test('renames on collision (foo.txt → foo (1).txt)', () async {
      final s = _setup();
      addTearDown(() async {
        await s.server.dispose();
        await s.trust.close();
        s.dir.deleteSync(recursive: true);
      });

      await s.server.start();
      s.trust.add(true);
      await _settle();

      final port = s.server.boundPort!;
      await (await _postUpload(
        port: port,
        fileName: 'foo.txt',
        body: utf8.encode('first'),
      )).drain<void>();
      await (await _postUpload(
        port: port,
        fileName: 'foo.txt',
        body: utf8.encode('second'),
      )).drain<void>();

      await _settle();

      final first = File('${s.dir.path}${Platform.pathSeparator}foo.txt');
      final second =
          File('${s.dir.path}${Platform.pathSeparator}foo (1).txt');
      expect(await first.readAsString(), 'first');
      expect(await second.readAsString(), 'second');
    });

    test('sanitizes path-traversal attempts in the filename header',
        () async {
      final s = _setup();
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
        fileName: '../../etc/passwd',
        body: utf8.encode('nope'),
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await _settle();

      // Nothing escaped the sandbox dir.
      final escaped = Directory(
          '${s.dir.parent.parent.path}${Platform.pathSeparator}etc');
      expect(escaped.existsSync(), isFalse,
          reason: 'should not have written outside the downloads dir');
      // And something landed inside it (sanitized).
      expect(s.dir.listSync(), isNotEmpty);
    });
  });
}
