import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/security/forget_service.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
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

  // The sender uses a *different* PairedDevicesStore so the receiver's
  // verifier rejects with 401. That's the precondition for triggering
  // reactive forget.
  late PairedDevicesStore senderPaired;
  late PeerCacheStore senderCache;
  late ForgetService senderForget;
  late StaticIdentityRepo senderIdentity;
  late TransferServiceImpl service;
  late PairedDevice senderViewOfReceiver;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_reactive401_');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    // Receiver: knows nobody. Any signed inbound is rejected with 401.
    receiverPaired = PairedDevicesStore(FakeSecureKeyValueStore());
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

    // Sender: thinks the receiver is paired (legacy entry that the
    // receiver no longer holds).
    senderPaired = PairedDevicesStore(FakeSecureKeyValueStore());
    senderViewOfReceiver = PairedDevice(
      deviceId: 'receiver-id',
      displayName: 'Receiver',
      psk: _psk(7),
      publicKey: _stubPub(7),
      certFingerprint: 'aa:bb:cc',
      pairedAt: DateTime.utc(2026, 5, 4),
    );
    await senderPaired.add(senderViewOfReceiver);
    senderCache = PeerCacheStore(prefs);
    senderIdentity = await StaticIdentityRepo.create(seed: 11);
    senderForget = ForgetService(
      pairedRepo: senderPaired,
      peerCache: senderCache,
      // Never invoked here — reactive 401 doesn't post anything.
      client: PairInviteClient(HttpClient()),
      identityRepo: senderIdentity,
    );

    httpClient = HttpFileClient(httpClient: HttpClient());
    service = TransferServiceImpl(
      client: httpClient,
      server: server,
      identityRepo: senderIdentity,
      pairedRepo: senderPaired,
      peerCache: senderCache,
      forget: senderForget,
    );
  });

  tearDown(() async {
    await service.dispose();
    httpClient.close();
    await server.dispose();
    await trust.close();
    await senderForget.dispose();
    await senderPaired.dispose();
    await receiverPaired.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  test('a 403 unknown-sender response from a peer that forgot us triggers '
      'reactive forget and emits a ForgetEvent with cause=reactive', () async {
    // The receiver knows nobody, so the verifier rejects with
    // unknownSender -> 403 + X-Sharer-Reason, which is the one signal
    // that drives reactive forget (audit #1).
    final received = <ForgetEvent>[];
    final sub = senderForget.events.listen(received.add);

    final transfers = <List<Transfer>>[];
    final tSub = service.watchAll().listen(transfers.add);

    final body = utf8.encode('hello');
    await service.send(
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

    // Give the upload future + reactive removal time to settle.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (received.isNotEmpty) break;
    }

    expect(received, hasLength(1),
        reason: 'reactive ForgetEvent should have fired');
    expect(received.first.cause, ForgetCause.reactive);
    expect(received.first.peerId, 'receiver-id');

    expect(await senderPaired.get('receiver-id'), isNull,
        reason: 'reactive forget should have removed the local pair');

    // The transfer itself ends in failed.
    expect(transfers.last.first.status, TransferStatus.failed);

    await sub.cancel();
    await tSub.cancel();
  });

  test('a transient 401 (signature mismatch from a known peer) does NOT '
      'trigger reactive forget — the pair stays intact', () async {
    // Audit #1: the receiver KNOWS this sender but under a different PSK,
    // so the signature mismatches -> bare 401 (transient), NOT a 403
    // unknown-sender. A still-valid pair must survive a transient
    // failure (clock skew, replay, wrong-PSK blip) without being
    // silently unpaired.
    await receiverPaired.add(PairedDevice(
      deviceId: senderIdentity.id,
      displayName: 'Sender',
      psk: _psk(8), // different PSK -> signature mismatch -> transient 401
      publicKey: _stubPub(7),
      pairedAt: DateTime.utc(2026, 5, 4),
    ));

    final received = <ForgetEvent>[];
    final sub = senderForget.events.listen(received.add);
    final transfers = <List<Transfer>>[];
    final tSub = service.watchAll().listen(transfers.add);

    final body = utf8.encode('hello');
    await service.send(
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

    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (transfers.isNotEmpty &&
          transfers.last.isNotEmpty &&
          transfers.last.first.status == TransferStatus.failed) {
        break;
      }
    }

    expect(received, isEmpty,
        reason: 'a transient 401 must NOT unpair a still-valid peer');
    expect(await senderPaired.get('receiver-id'), isNotNull,
        reason: 'the pair stays intact on a transient failure');
    expect(transfers.last.first.status, TransferStatus.failed);

    await sub.cancel();
    await tSub.cancel();
  });

  test('a successful upload does NOT trigger reactive forget', () async {
    // Restart with the receiver actually knowing the sender's pair.
    await receiverPaired.add(PairedDevice(
      deviceId: senderIdentity.id,
      displayName: 'Sender',
      psk: senderViewOfReceiver.psk, // same PSK both sides
      publicKey: _stubPub(7),
      pairedAt: DateTime.utc(2026, 5, 4),
    ));

    final received = <ForgetEvent>[];
    final sub = senderForget.events.listen(received.add);

    final body = utf8.encode('hello');
    await service.send(
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
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(received, isEmpty);
    expect(await senderPaired.get('receiver-id'), isNotNull);

    await sub.cancel();
  });
}
