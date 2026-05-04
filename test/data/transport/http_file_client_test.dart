import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/transport/http_file_client.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/domain/entities/device_identity.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory tmpDir;
  late StreamController<bool> trust;
  late HttpFileServer server;
  late HttpFileClient client;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_client_test_');
    trust = StreamController<bool>.broadcast();
    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      port: 0,
    );
    client = HttpFileClient();
    await server.start();
    trust.add(true);
    await _settle();
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await trust.close();
    tmpDir.deleteSync(recursive: true);
  });

  test('uploads a streamed payload end-to-end', () async {
    const content = 'Slice 3 transport works end-to-end!';
    final bytes = utf8.encode(content);

    final result = await client.upload(
      host: '127.0.0.1',
      port: server.boundPort!,
      file: FilePayload(
        fileName: 'roundtrip.txt',
        sizeBytes: bytes.length,
        bytes: Stream.fromIterable([bytes]),
      ),
      sender: const DeviceIdentity(id: 'sender-id', name: 'Sender'),
    );

    expect(result.bytesSent, bytes.length);
    expect(result.savedPath, endsWith('roundtrip.txt'));

    final saved = File('${tmpDir.path}${Platform.pathSeparator}roundtrip.txt');
    expect(await saved.readAsString(), content);
  });

  test('emits cumulative progress for each streamed chunk', () async {
    final chunks = [
      List.filled(1000, 0x41),
      List.filled(2000, 0x42),
      List.filled(500, 0x43),
    ];
    final total = chunks.fold<int>(0, (acc, c) => acc + c.length);

    final reported = <int>[];
    await client.upload(
      host: '127.0.0.1',
      port: server.boundPort!,
      file: FilePayload(
        fileName: 'chunked.bin',
        sizeBytes: total,
        bytes: Stream.fromIterable(chunks),
      ),
      sender: const DeviceIdentity(id: 'sender-id', name: 'Sender'),
      onProgress: reported.add,
    );

    expect(reported, [1000, 3000, 3500]);
  });

  test('signed upload round-trips through a real verifier', () async {
    // Tear down the unsigned-only setUp server and bring up one that
    // shares a verifier+repo with this test.
    client.close();
    await server.dispose();
    await trust.close();

    trust = StreamController<bool>.broadcast();
    final secure = FakeSecureKeyValueStore();
    final paired = PairedDevicesStore(secure);
    addTearDown(paired.dispose);

    final psk =
        Uint8List.fromList(List<int>.generate(32, (i) => (3 + i) & 0xff));
    await paired.add(PairedDevice(
      deviceId: 'sender-id',
      displayName: 'Sender',
      psk: psk,
      pairedAt: DateTime.utc(2026, 5, 4),
    ));

    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      verifier: HmacVerifier(paired),
      port: 0,
    );
    client = HttpFileClient();
    await server.start();
    trust.add(true);
    await _settle();

    final bytes = utf8.encode('signed bytes');
    final result = await client.upload(
      host: '127.0.0.1',
      port: server.boundPort!,
      file: FilePayload(
        fileName: 'signed.txt',
        sizeBytes: bytes.length,
        bytes: Stream.fromIterable([bytes]),
      ),
      sender: const DeviceIdentity(id: 'sender-id', name: 'Sender'),
      recipientPsk: psk,
    );

    expect(result.bytesSent, bytes.length);
    expect(result.savedPath, endsWith('signed.txt'));
  });

  test('signed upload with the wrong PSK is rejected by the server',
      () async {
    client.close();
    await server.dispose();
    await trust.close();

    trust = StreamController<bool>.broadcast();
    final secure = FakeSecureKeyValueStore();
    final paired = PairedDevicesStore(secure);
    addTearDown(paired.dispose);

    final realPsk =
        Uint8List.fromList(List<int>.generate(32, (i) => (3 + i) & 0xff));
    final wrongPsk =
        Uint8List.fromList(List<int>.generate(32, (i) => (9 + i) & 0xff));
    await paired.add(PairedDevice(
      deviceId: 'sender-id',
      displayName: 'Sender',
      psk: realPsk,
      pairedAt: DateTime.utc(2026, 5, 4),
    ));

    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      verifier: HmacVerifier(paired),
      port: 0,
    );
    client = HttpFileClient();
    await server.start();
    trust.add(true);
    await _settle();

    final bytes = utf8.encode('intercepted');
    expect(
      () => client.upload(
        host: '127.0.0.1',
        port: server.boundPort!,
        file: FilePayload(
          fileName: 'attempt.txt',
          sizeBytes: bytes.length,
          bytes: Stream.fromIterable([bytes]),
        ),
        sender: const DeviceIdentity(id: 'sender-id', name: 'Sender'),
        recipientPsk: wrongPsk,
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('throws on non-2xx response (server-side rejection)', () async {
    // Force the server to reject by sending an empty-name request via a
    // dedicated helper; here we simulate via a malformed payload.
    final badClient = HttpClient();
    try {
      final req = await badClient.postUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}/upload'),
      );
      req.headers.contentLength = 0;
      final resp = await req.close();
      // Sanity: server rejects empty filename with 400.
      expect(resp.statusCode, HttpStatus.badRequest);
      await resp.drain<void>();
    } finally {
      badClient.close();
    }

    // Now confirm HttpFileClient surfaces a thrown exception when the
    // server rejects (we hit the same 400 by sending an empty name via
    // a payload with empty fileName).
    expect(
      () => client.upload(
        host: '127.0.0.1',
        port: server.boundPort!,
        file: FilePayload(
          fileName: '', // server rejects
          sizeBytes: 0,
          bytes: const Stream.empty(),
        ),
        sender: const DeviceIdentity(id: 'sender-id', name: 'Sender'),
      ),
      throwsA(isA<HttpException>()),
    );
  });
}
