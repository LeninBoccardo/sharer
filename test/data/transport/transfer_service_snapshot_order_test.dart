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

// Audit #51: _snapshot() builds the most-recent-first list from a cached
// _orderedIds order maintained incrementally in _put/_evictOldTerminals,
// instead of copy+sorting _byId on every emit. This test exercises that
// path end-to-end: two sends settle in most-recent-first order and the
// relative order never flips across the value updates (progress/completion)
// that arrive while both are present.

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

Uint8List _stubPub(int seed) => Uint8List.fromList(
    List<int>.generate(32, (i) => (200 + seed + i) & 0xff));

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
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

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_snap_order_');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    senderIdentity = await StaticIdentityRepo.create(seed: 3);

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

  Peer makePeer() => Peer(
        id: 'receiver-id',
        name: 'Receiver',
        host: '127.0.0.1',
        port: server.boundPort!,
        isPaired: true,
        lastSeen: DateTime.utc(2026, 5, 5),
      );

  test('snapshots are most-recent-first and value updates never reorder '
      'two transfers (audit #51)', () async {
    final snapshots = <List<Transfer>>[];
    final sub = service.watchAll().listen(snapshots.add);

    // A is sent first, then B. send() _puts each synchronously before
    // returning, so the cached order becomes most-recent-first: [B, A].
    final a = await service.send(
      peer: makePeer(),
      file: FilePayload(
        fileName: 'a.bin',
        sizeBytes: 5,
        bytes: Stream.value(utf8.encode('aaaaa')),
      ),
    );
    final b = await service.send(
      peer: makePeer(),
      file: FilePayload(
        fileName: 'b.bin',
        sizeBytes: 5,
        bytes: Stream.value(utf8.encode('bbbbb')),
      ),
    );

    // Wait until both transfers have settled (completed) and both appear.
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final last = snapshots.isNotEmpty ? snapshots.last : const <Transfer>[];
      final byId = {for (final t in last) t.id: t};
      if (byId[a.id]?.isTerminal == true &&
          byId[b.id]?.isTerminal == true) {
        break;
      }
    }

    final last = snapshots.last;
    final ids = last.map((t) => t.id).toList();
    expect(ids.indexOf(b.id), greaterThanOrEqualTo(0));
    expect(ids.indexOf(a.id), greaterThanOrEqualTo(0));
    expect(ids.indexOf(b.id), lessThan(ids.indexOf(a.id)),
        reason: 'B was sent later, so it must sort most-recent-first');

    // Stability: in EVERY snapshot where both ids appear, B precedes A —
    // proving the progress/completion value updates never reordered them.
    for (final snap in snapshots) {
      final ia = snap.indexWhere((t) => t.id == a.id);
      final ib = snap.indexWhere((t) => t.id == b.id);
      if (ia >= 0 && ib >= 0) {
        expect(ib, lessThan(ia),
            reason: 'a value update must not move B behind A');
      }
    }

    await sub.cancel();
  });
}
