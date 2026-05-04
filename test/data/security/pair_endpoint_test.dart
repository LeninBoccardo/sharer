import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pairing_client.dart';
import 'package:sharer/data/security/pairing_service.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/domain/entities/device_identity.dart';
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
  late StaticIdentityRepo identity;
  late PairingService pairing;
  late HttpFileServer server;
  late PairingClient client;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('sharer_pair_test_');
    trust = StreamController<bool>.broadcast();
    secure = FakeSecureKeyValueStore();
    paired = PairedDevicesStore(secure);
    identity = StaticIdentityRepo(id: 'lenin-pc', name: 'Lenin-PC');
    pairing = PairingService(
      paired,
      identity,
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

  test('responder can complete pairing end-to-end', () async {
    final offer = await pairing.createOffer(
      endpoint: '127.0.0.1:${server.boundPort}',
    );

    final result = await client.postCompletion(
      offer: offer,
      responder: const DeviceIdentity(id: 'realme', name: 'Realme'),
    );
    expect(result, PairingPostResult.ok);

    final all = await paired.getAll();
    expect(all.single.deviceId, 'realme');
    expect(all.single.psk, offer.psk);
  });

  test('completion fails when offer was never created', () async {
    final ghostOffer = PairingOffer(
      offerId: 'unknown',
      psk: (await pairing.createOffer(
        endpoint: '127.0.0.1:${server.boundPort}',
      ))
          .psk,
      numericCode: '000000',
      endpoint: '127.0.0.1:${server.boundPort}',
      initiatorId: 'lenin-pc',
      initiatorName: 'Lenin-PC',
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
    );

    final result = await client.postCompletion(
      offer: ghostOffer,
      responder: const DeviceIdentity(id: 'realme', name: 'Realme'),
    );
    expect(result, PairingPostResult.rejected);
    expect(await paired.getAll(), isEmpty);
  });

  test('PairingClient surfaces network errors as networkError', () async {
    final offer = await pairing.createOffer(
      endpoint: '127.0.0.1:${server.boundPort}',
    );
    // Forge an offer pointing at a closed port.
    final brokenOffer = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoint: '127.0.0.1:1', // nothing listens on port 1
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      expiresAt: offer.expiresAt,
    );
    final result = await client.postCompletion(
      offer: brokenOffer,
      responder: const DeviceIdentity(id: 'realme', name: 'Realme'),
    );
    expect(result, PairingPostResult.networkError);
  });

  test('PairingClient rejects malformed endpoint without hitting the network',
      () async {
    final offer = await pairing.createOffer(
      endpoint: '127.0.0.1:${server.boundPort}',
    );
    final brokenOffer = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoint: 'not-a-host-port',
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      expiresAt: offer.expiresAt,
    );
    final result = await client.postCompletion(
      offer: brokenOffer,
      responder: const DeviceIdentity(id: 'realme', name: 'Realme'),
    );
    expect(result, PairingPostResult.malformedEndpoint);
  });
}
