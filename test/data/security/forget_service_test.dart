import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/security/forget_service.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/storage/peer_cache_store.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/entities/peer.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

class _MockClient extends Mock implements PairInviteClient {}

PairedDevice _peer({
  String id = 'realme',
  String name = 'Realme',
  String? cert = 'aa:bb:cc',
}) =>
    PairedDevice(
      deviceId: id,
      displayName: name,
      psk: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      publicKey: Uint8List.fromList(List<int>.generate(32, (i) => 200 + i)),
      certFingerprint: cert,
      pairedAt: DateTime.utc(2026, 5, 4),
    );

void main() {
  setUpAll(() {
    // Mocktail needs fallbacks for non-primitive named-arg defaults.
  });

  late PairedDevicesStore paired;
  late PeerCacheStore cache;
  late StaticIdentityRepo identity;
  late _MockClient client;
  late ForgetService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    paired = PairedDevicesStore(FakeSecureKeyValueStore());
    cache = PeerCacheStore(prefs);
    identity = await StaticIdentityRepo.create(seed: 9, name: 'Lenin-PC');
    client = _MockClient();
    when(() => client.postPeerForgotYou(
          host: any(named: 'host'),
          port: any(named: 'port'),
          senderId: any(named: 'senderId'),
          signatureBase64: any(named: 'signatureBase64'),
          peerCertFingerprintSha256: any(named: 'peerCertFingerprintSha256'),
        )).thenAnswer((_) async => true);
    service = ForgetService(
      pairedRepo: paired,
      peerCache: cache,
      client: client,
      identityRepo: identity,
    );
  });

  tearDown(() async {
    await service.dispose();
    await paired.dispose();
  });

  group('forgetPeer (proactive — we initiated)', () {
    test('removes locally + posts to peer when we have a cached host '
        'and a cert fingerprint', () async {
      final peer = _peer();
      await paired.add(peer);
      await cache.cacheAddress(
        deviceId: peer.deviceId,
        host: '192.168.68.56',
        port: 8080,
      );

      await service.forgetPeer(peer);

      verify(() => client.postPeerForgotYou(
            host: '192.168.68.56',
            port: 8080,
            senderId: identity.id,
            signatureBase64: any(named: 'signatureBase64'),
            peerCertFingerprintSha256: 'aa:bb:cc',
          )).called(1);
      expect(await paired.get(peer.deviceId), isNull);
      expect(await cache.getById(peer.deviceId), isNull);
    });

    test('skips the POST when no cached host is known', () async {
      final peer = _peer();
      await paired.add(peer);
      // No cache entry for this peer.

      await service.forgetPeer(peer);

      verifyNever(() => client.postPeerForgotYou(
            host: any(named: 'host'),
            port: any(named: 'port'),
            senderId: any(named: 'senderId'),
            signatureBase64: any(named: 'signatureBase64'),
            peerCertFingerprintSha256:
                any(named: 'peerCertFingerprintSha256'),
          ));
      expect(await paired.get(peer.deviceId), isNull);
    });

    test('skips the POST when the PairedDevice has no cert fingerprint '
        '(legacy entry from pre-5.1 pairing)', () async {
      final peer = _peer(cert: null);
      await paired.add(peer);
      await cache.cacheAddress(
        deviceId: peer.deviceId,
        host: '192.168.68.56',
        port: 8080,
      );

      await service.forgetPeer(peer);

      verifyNever(() => client.postPeerForgotYou(
            host: any(named: 'host'),
            port: any(named: 'port'),
            senderId: any(named: 'senderId'),
            signatureBase64: any(named: 'signatureBase64'),
            peerCertFingerprintSha256:
                any(named: 'peerCertFingerprintSha256'),
          ));
      expect(await paired.get(peer.deviceId), isNull);
    });

    test('still removes locally when the peer POST fails', () async {
      when(() => client.postPeerForgotYou(
            host: any(named: 'host'),
            port: any(named: 'port'),
            senderId: any(named: 'senderId'),
            signatureBase64: any(named: 'signatureBase64'),
            peerCertFingerprintSha256:
                any(named: 'peerCertFingerprintSha256'),
          )).thenAnswer((_) async => false);

      final peer = _peer();
      await paired.add(peer);
      await cache.cacheAddress(
        deviceId: peer.deviceId,
        host: '192.168.68.56',
        port: 8080,
      );

      await service.forgetPeer(peer);

      expect(await paired.get(peer.deviceId), isNull);
      expect(await cache.getById(peer.deviceId), isNull);
    });
  });

  group('recordRemoteForgot (proactive incoming)', () {
    test('removes locally + emits a proactive event', () async {
      final peer = _peer();
      await paired.add(peer);
      await cache.cacheAddress(
        deviceId: peer.deviceId,
        host: '192.168.68.56',
        port: 8080,
      );
      final received = <ForgetEvent>[];
      final sub = service.events.listen(received.add);

      await service.recordRemoteForgot(peer);
      await Future<void>.delayed(Duration.zero);

      expect(await paired.get(peer.deviceId), isNull);
      expect(await cache.getById(peer.deviceId), isNull);
      expect(received, hasLength(1));
      expect(received.first.cause, ForgetCause.proactive);
      expect(received.first.peerName, 'Realme');
      expect(received.first.peerId, 'realme');

      await sub.cancel();
    });
  });

  group('recordReactive401 (transport detected silent unpair)', () {
    test('removes locally + emits a reactive event', () async {
      final peer = _peer();
      await paired.add(peer);
      final received = <ForgetEvent>[];
      final sub = service.events.listen(received.add);

      await service.recordReactive401(peer);
      await Future<void>.delayed(Duration.zero);

      expect(await paired.get(peer.deviceId), isNull);
      expect(received, hasLength(1));
      expect(received.first.cause, ForgetCause.reactive);

      await sub.cancel();
    });

    test('does not POST anything (peer already removed us — telling them '
        'is pointless)', () async {
      final peer = _peer();
      await paired.add(peer);

      await service.recordReactive401(peer);

      verifyNever(() => client.postPeerForgotYou(
            host: any(named: 'host'),
            port: any(named: 'port'),
            senderId: any(named: 'senderId'),
            signatureBase64: any(named: 'signatureBase64'),
            peerCertFingerprintSha256:
                any(named: 'peerCertFingerprintSha256'),
          ));
    });
  });

  // Compile-time witness: verify that an unused Peer constructor reference
  // doesn't trip the linter. (Ensures tests still compile after a Peer
  // shape change without a stale unused import.)
  test('Peer is reachable from this test file', () {
    final p = Peer(
      id: 'sentinel',
      name: 'Sentinel',
      lastSeen: DateTime.utc(2026, 5, 5),
    );
    expect(p.id, 'sentinel');
  });
}
