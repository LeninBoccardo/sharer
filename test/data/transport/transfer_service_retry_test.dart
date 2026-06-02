import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/storage/peer_cache_store.dart';
import 'package:sharer/data/transport/http_file_client.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/transfer_service_impl.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

Uint8List _stubPub(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (200 + seed + i) & 0xff));

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Transfer? _find(List<Transfer> snapshot, String id) {
  for (final t in snapshot) {
    if (t.id == id) return t;
  }
  return null;
}

/// Polls the watchAll log until [pred] holds for transfer [id].
Future<Transfer> _waitFor(
  List<List<Transfer>> log,
  String id,
  bool Function(Transfer) pred,
) async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    for (var j = log.length - 1; j >= 0; j--) {
      final t = _find(log[j], id);
      if (t != null && pred(t)) return t;
    }
  }
  throw StateError('condition never met for $id');
}

void main() {
  late Directory tmpDir;
  late StreamController<bool> trust;
  late HttpFileServer server;
  late HttpFileClient httpClient;
  late PairedDevicesStore receiverPaired;
  late PairedDevicesStore senderPaired;
  late PeerCacheStore senderCache;
  late StaticIdentityRepo senderIdentity;
  late TransferServiceImpl service;

  Peer peer() => Peer(
        id: 'receiver-id',
        name: 'Receiver',
        host: '127.0.0.1',
        port: server.boundPort!,
        isPaired: true,
        lastSeen: DateTime.utc(2026, 5, 5),
      );

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_retry_');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    senderIdentity = await StaticIdentityRepo.create(seed: 11);

    receiverPaired = PairedDevicesStore(FakeSecureKeyValueStore());
    await receiverPaired.add(PairedDevice(
      deviceId: senderIdentity.id,
      displayName: 'Sender',
      psk: _psk(7),
      publicKey: _stubPub(7),
      pairedAt: DateTime.utc(2026, 5, 4),
    ));
    trust = StreamController<bool>.broadcast();
    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      verifier: HmacVerifier(receiverPaired,
          localDeviceId: Future.value('receiver-id')),
      port: 0,
    );
    await server.start();
    trust.add(true);
    await _settle();

    senderPaired = PairedDevicesStore(FakeSecureKeyValueStore());
    await senderPaired.add(PairedDevice(
      deviceId: 'receiver-id',
      displayName: 'Receiver',
      psk: _psk(7),
      publicKey: _stubPub(7),
      certFingerprint: 'aa:bb:cc',
      pairedAt: DateTime.utc(2026, 5, 4),
    ));
    senderCache = PeerCacheStore(prefs);

    httpClient = HttpFileClient(httpClient: HttpClient());
    service = TransferServiceImpl(
      client: httpClient,
      server: server,
      identityRepo: senderIdentity,
      pairedRepo: senderPaired,
      peerCache: senderCache,
    );
  });

  tearDown(() async {
    await service.dispose();
    httpClient.close();
    await server.dispose();
    await trust.close();
    await senderPaired.dispose();
    await receiverPaired.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  test('retry() re-opens the source from disk and completes the transfer',
      () async {
    final transfers = <List<Transfer>>[];
    final sub = service.watchAll().listen(transfers.add);

    // A real file the retry will re-stream from disk.
    final srcPath = '${tmpDir.path}${Platform.pathSeparator}payload.bin';
    final bytes =
        Uint8List.fromList(List<int>.generate(5000, (i) => i & 0xff));
    File(srcPath).writeAsBytesSync(bytes);

    // FIRST attempt fails: the initial body stream errors immediately. The
    // reopen factory points at the real file so a retry can re-stream it.
    final transfer = await service.send(
      peer: peer(),
      file: FilePayload(
        fileName: 'payload.bin',
        sizeBytes: bytes.length,
        bytes: Stream<List<int>>.error(Exception('boom')),
      ),
      reopen: () => File(srcPath).openRead(),
    );
    expect(transfer.status, TransferStatus.inProgress);

    final failed = await _waitFor(
        transfers, transfer.id, (t) => t.status == TransferStatus.failed);
    expect(failed.canRetry, isTrue,
        reason: 'a send given a reopen factory is retryable');

    // Retry: rebuild() re-opens File(srcPath) and streams it to the live
    // server, reusing the same id.
    await service.retry(transfer.id);

    final done = await _waitFor(
        transfers, transfer.id, (t) => t.status == TransferStatus.completed);
    expect(done.bytesTransferred, bytes.length,
        reason: 'the full file was re-streamed from disk');
    expect(done.id, transfer.id, reason: 'retry reuses the same id in place');

    await sub.cancel();
  });

  test('retry() is a no-op for an unknown id (does not throw)', () async {
    await service.retry('nope');
  });

  test('retry() is a no-op for a completed transfer and the spec is dropped',
      () async {
    final transfers = <List<Transfer>>[];
    final sub = service.watchAll().listen(transfers.add);

    final body = utf8.encode('hello');
    final transfer = await service.send(
      peer: peer(),
      file: FilePayload(
        fileName: 'note.txt',
        sizeBytes: body.length,
        bytes: Stream.value(body),
      ),
      reopen: () => Stream.value(body),
    );

    final done = await _waitFor(
        transfers, transfer.id, (t) => t.status == TransferStatus.completed);
    expect(done.status, TransferStatus.completed);

    // Completed -> not failed -> retry must be a no-op, and the spec was
    // dropped on completion so it cannot re-open a (possibly deleted)
    // source.
    await service.retry(transfer.id);
    await _settle();
    final after = _find(transfers.last, transfer.id)!;
    expect(after.status, TransferStatus.completed);

    await sub.cancel();
  });

  test('a send WITHOUT a reopen factory is not retryable', () async {
    final transfers = <List<Transfer>>[];
    final sub = service.watchAll().listen(transfers.add);

    final transfer = await service.send(
      peer: peer(),
      file: FilePayload(
        fileName: 'x.bin',
        sizeBytes: 3,
        bytes: Stream<List<int>>.error(Exception('boom')),
      ),
      // no reopen
    );

    final failed = await _waitFor(
        transfers, transfer.id, (t) => t.status == TransferStatus.failed);
    expect(failed.canRetry, isFalse);

    // No spec -> retry is a no-op (stays failed).
    await service.retry(transfer.id);
    await _settle();
    expect(_find(transfers.last, transfer.id)!.status, TransferStatus.failed);

    await sub.cancel();
  });
}
