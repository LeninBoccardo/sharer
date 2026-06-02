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
    tmpDir = Directory.systemTemp.createTempSync('sharer_cancel_');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    senderIdentity = await StaticIdentityRepo.create(seed: 11);

    // Receiver knows the sender under the same PSK so signed uploads pass
    // the HMAC gate — we want the transfer to actually start streaming
    // (not get rejected) so cancel() has an in-flight upload to abort.
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
      // Audit #30: the sender signs with recipientDeviceId = peer.id
      // ('receiver-id'), so the receiver verifies against that local id.
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

  test('cancel() on an in-flight outgoing transfer drives it to cancelled, '
      'not failed', () async {
    final transfers = <List<Transfer>>[];
    final tSub = service.watchAll().listen(transfers.add);

    // A payload that streams slowly so the upload is still in flight when
    // we call cancel(). Each chunk is gated behind a short delay; the
    // declared sizeBytes is larger than what we ever actually emit, so the
    // stream never completes on its own within the test window.
    final chunk = Uint8List.fromList(List<int>.filled(4096, 0x41));
    final controller = StreamController<List<int>>();
    var pushed = 0;
    Timer.periodic(const Duration(milliseconds: 20), (t) {
      if (controller.isClosed) {
        t.cancel();
        return;
      }
      controller.add(chunk);
      pushed++;
      if (pushed >= 50) t.cancel();
    });

    final transfer = await service.send(
      peer: Peer(
        id: 'receiver-id',
        name: 'Receiver',
        host: '127.0.0.1',
        port: server.boundPort!,
        isPaired: true,
        lastSeen: DateTime.utc(2026, 5, 5),
      ),
      file: FilePayload(
        fileName: 'big.bin',
        sizeBytes: 4096 * 1000, // far more than we will ever emit
        bytes: controller.stream,
      ),
    );

    expect(transfer.status, TransferStatus.inProgress);

    // Let a few chunks flow so the upload is genuinely mid-stream.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await service.cancel(transfer.id);

    // Wait for the cancelled status to land.
    Transfer? last;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      last = transfers.isNotEmpty && transfers.last.isNotEmpty
          ? transfers.last.firstWhere(
              (t) => t.id == transfer.id,
              orElse: () => transfers.last.first,
            )
          : null;
      if (last != null && last.isTerminal) break;
    }

    expect(last, isNotNull);
    expect(last!.status, TransferStatus.cancelled,
        reason: 'a user-cancelled upload must end cancelled, not failed');

    await controller.close();
    await tSub.cancel();
  });

  test('cancel() is an idempotent no-op for an unknown transfer id', () async {
    // Must not throw.
    await service.cancel('does-not-exist');
  });

  test('cancel() after a transfer has already completed is a no-op', () async {
    final transfers = <List<Transfer>>[];
    final tSub = service.watchAll().listen(transfers.add);

    final body = utf8.encode('hello');
    final transfer = await service.send(
      peer: Peer(
        id: 'receiver-id',
        name: 'Receiver',
        host: '127.0.0.1',
        port: server.boundPort!,
        isPaired: true,
        lastSeen: DateTime.utc(2026, 5, 5),
      ),
      file: FilePayload(
        fileName: 'note.txt',
        sizeBytes: body.length,
        bytes: Stream.value(body),
      ),
    );

    // Wait for completion.
    Transfer? last;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      last = transfers.isNotEmpty && transfers.last.isNotEmpty
          ? transfers.last.firstWhere(
              (t) => t.id == transfer.id,
              orElse: () => transfers.last.first,
            )
          : null;
      if (last != null && last.isTerminal) break;
    }
    expect(last!.status, TransferStatus.completed);

    // Cancelling a finished transfer must not flip it to cancelled.
    await service.cancel(transfer.id);
    await _settle();
    final after = transfers.last.firstWhere((t) => t.id == transfer.id);
    expect(after.status, TransferStatus.completed);

    await tSub.cancel();
  });
}
