import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pairing_client.dart';
import 'package:sharer/data/security/pairing_service.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/domain/entities/pairing_offer.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory tmpDir;
  late StreamController<bool> trust;
  late FakeSecureKeyValueStore secure;
  late PairedDevicesStore paired;
  late StaticIdentityRepo initiatorIdentity;
  late StaticIdentityRepo responderIdentity;
  late PairingService pairing;
  late HttpFileServer server;
  late PairingClient client;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_pair_test_');
    trust = StreamController<bool>.broadcast();
    secure = FakeSecureKeyValueStore();
    paired = PairedDevicesStore(secure);
    initiatorIdentity =
        await StaticIdentityRepo.create(seed: 1, name: 'Lenin-PC');
    responderIdentity =
        await StaticIdentityRepo.create(seed: 2, name: 'Realme');
    pairing = PairingService(
      paired,
      initiatorIdentity,
      random: Random(42),
      now: DateTime.now,
    );
    server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmpDir),
      isTrusted: trust.stream,
      pairing: pairing,
      port: 0,
    );
    await server.start();
    trust.add(true);
    await _settle();
    client = PairingClient();
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await trust.close();
    await pairing.dispose();
    await paired.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  Future<PairingPostResult> postAs(PairingOffer offer) async {
    final responder = await responderIdentity.get();
    return client.postCompletion(
      offer: offer,
      responder: responder,
      identityRepo: responderIdentity,
    );
  }

  test('responder can complete pairing end-to-end', () async {
    final offer = await pairing.createOffer(
      endpoints: ['127.0.0.1:${server.boundPort}'],
    );

    final result = await postAs(offer);
    expect(result, PairingPostResult.ok);

    final all = await paired.getAll();
    expect(all.single.deviceId, responderIdentity.id);
    expect(all.single.psk, offer.psk);
    expect(all.single.publicKey, responderIdentity.publicKey);
  });

  test('completion fails when offer was never created', () async {
    final live = await pairing.createOffer(
      endpoints: ['127.0.0.1:${server.boundPort}'],
    );
    // Forge an offer with a fake offerId but valid signature against
    // the initiator's key — server still rejects (unknown offerId).
    final ghostOffer = PairingOffer(
      offerId: 'unknown',
      psk: live.psk,
      numericCode: '000000',
      endpoints: ['127.0.0.1:${server.boundPort}'],
      initiatorId: initiatorIdentity.id,
      initiatorName: 'Lenin-PC',
      initiatorPublicKey: initiatorIdentity.publicKey,
      signature: Uint8List(64),
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
    );

    final result = await postAs(ghostOffer);
    expect(result, PairingPostResult.rejected);
    expect(await paired.getAll(), isEmpty);
  });

  test('PairingClient surfaces network errors as networkError', () async {
    final offer = await pairing.createOffer(
      endpoints: ['127.0.0.1:${server.boundPort}'],
    );
    final brokenOffer = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: const ['127.0.0.1:1'],
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      signature: offer.signature,
      expiresAt: offer.expiresAt,
    );
    expect(await postAs(brokenOffer), PairingPostResult.networkError);
  });

  test('PairingClient rejects malformed endpoint without hitting the network',
      () async {
    final offer = await pairing.createOffer(
      endpoints: ['127.0.0.1:${server.boundPort}'],
    );
    final brokenOffer = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: const ['not-a-host-port'],
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      signature: offer.signature,
      expiresAt: offer.expiresAt,
    );
    expect(await postAs(brokenOffer), PairingPostResult.malformedEndpoint);
  });

  test('PairingClient prefers a reachable endpoint and ignores unreachable ones',
      () async {
    final offer = await pairing.createOffer(
      endpoints: ['127.0.0.1:1', '127.0.0.1:${server.boundPort}'],
    );
    final result = await postAs(offer);
    expect(result, PairingPostResult.ok,
        reason: 'should fall through to the working endpoint');
    expect((await paired.getAll()).single.deviceId, responderIdentity.id);
  });
}
