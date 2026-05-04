import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/discovery/mdns_backend.dart';
import 'package:sharer/data/discovery/mdns_peer_discovery.dart';
import 'package:sharer/domain/entities/device_identity.dart';
import 'package:sharer/domain/repositories/device_identity_repository.dart';

import '../../fakes/fake_mdns_backend.dart';

class _StaticIdentityRepo implements DeviceIdentityRepository {
  _StaticIdentityRepo({required this.id, required this.name});

  final String id;
  final String name;

  @override
  Future<DeviceIdentity> get() async => DeviceIdentity(id: id, name: name);

  @override
  Future<void> rename(String name) async => throw UnimplementedError();
}

/// Pumps the microtask + small timer queue so async listeners and the
/// reconciler get a chance to settle before assertions.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

({MdnsPeerDiscovery discovery, FakeMdnsBackend backend, StreamController<bool> trust}) _setup({
  String selfId = 'self-id',
  String selfName = 'Self',
}) {
  final backend = FakeMdnsBackend();
  final trust = StreamController<bool>.broadcast();
  final discovery = MdnsPeerDiscovery(
    backend: backend,
    identityRepo: _StaticIdentityRepo(id: selfId, name: selfName),
    isTrusted: trust.stream,
  );
  return (discovery: discovery, backend: backend, trust: trust);
}

MdnsEvent _resolved({
  required String name,
  required String deviceId,
  String? displayName,
  String host = '192.168.1.42',
  int port = 8080,
}) {
  return MdnsEvent(
    kind: MdnsEventKind.resolved,
    service: MdnsService(
      name: name,
      attributes: {
        'deviceId': deviceId,
        'name': ?displayName,
      },
      host: host,
      port: port,
    ),
  );
}

void main() {
  group('MdnsPeerDiscovery — trust gating', () {
    test('does nothing before start()', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      s.trust.add(true);
      await _settle();

      expect(s.backend.activeBroadcasters, isEmpty);
      expect(s.backend.activeObservers, isEmpty);
    });

    test('does nothing on untrusted network', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(false);
      await _settle();

      expect(s.backend.activeBroadcasters, isEmpty);
      expect(s.backend.activeObservers, isEmpty);
    });

    test('starts broadcaster + observer when trusted', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      expect(s.backend.activeBroadcasters, hasLength(1));
      expect(s.backend.activeObservers, hasLength(1));
    });

    test('stops both + clears peers when untrusted', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      // Discover a peer.
      s.backend.activeObservers.first.emit(_resolved(
        name: 'sharer-abc',
        deviceId: 'peer-1',
        displayName: 'Other Device',
      ));
      await _settle();
      expect((await s.discovery.watchPeers().first), hasLength(1));

      // Untrust → everything stops, peers cleared.
      s.trust.add(false);
      await _settle();

      expect(s.backend.activeBroadcasters, isEmpty);
      expect(s.backend.activeObservers, isEmpty);
      expect((await s.discovery.watchPeers().first), isEmpty);
    });

    test('rapid trust → untrust → trust converges to trusted', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      s.trust.add(false);
      s.trust.add(true);
      await _settle();

      // Final state: enabled, exactly one active handle each.
      expect(s.backend.activeBroadcasters, hasLength(1));
      expect(s.backend.activeObservers, hasLength(1));
    });

    test('rapid trust → untrust converges to untrusted', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      s.trust.add(false);
      await _settle();

      expect(s.backend.activeBroadcasters, isEmpty);
      expect(s.backend.activeObservers, isEmpty);
    });

    test('repeated trust=true does not start a second handle', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();
      s.trust.add(true);
      await _settle();

      expect(s.backend.activeBroadcasters, hasLength(1));
      expect(s.backend.activeObservers, hasLength(1));
    });

    test('stop() tears everything down regardless of trust state', () async {
      final s = _setup();
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();
      expect(s.backend.activeObservers, hasLength(1));

      await s.discovery.stop();

      expect(s.backend.activeBroadcasters, isEmpty);
      expect(s.backend.activeObservers, isEmpty);
    });
  });

  group('MdnsPeerDiscovery — peer events', () {
    test('adds a peer on resolved event with deviceId', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      s.backend.activeObservers.first.emit(_resolved(
        name: 'sharer-xyz',
        deviceId: 'peer-1',
        displayName: 'Phone',
        host: '10.0.0.5',
        port: 9000,
      ));
      await _settle();

      final peers = await s.discovery.watchPeers().first;
      expect(peers, hasLength(1));
      expect(peers.first.id, 'peer-1');
      expect(peers.first.name, 'Phone');
      expect(peers.first.host, '10.0.0.5');
      expect(peers.first.port, 9000);
      expect(peers.first.isPaired, isFalse);
    });

    test('falls back to mDNS service name when TXT name attr is missing',
        () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      s.backend.activeObservers.first.emit(_resolved(
        name: 'Some Legacy Name',
        deviceId: 'peer-1',
        // no displayName attribute
      ));
      await _settle();

      final peers = await s.discovery.watchPeers().first;
      expect(peers.single.name, 'Some Legacy Name');
    });

    test('skips self by deviceId even if mDNS name was renamed by NSD',
        () async {
      final s = _setup(selfId: 'self-id', selfName: 'Self Display');
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      // Simulate NSD auto-renaming our own broadcast (the "(2)" issue).
      s.backend.activeObservers.first.emit(_resolved(
        name: 'sharer-aaa (2)',
        deviceId: 'self-id',
        displayName: 'Self Display',
      ));
      await _settle();

      expect((await s.discovery.watchPeers().first), isEmpty);
    });

    test('skips services without a deviceId TXT attr', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      s.backend.activeObservers.first.emit(MdnsEvent(
        kind: MdnsEventKind.resolved,
        service: const MdnsService(
          name: 'whatever',
          attributes: {},
          host: '1.2.3.4',
          port: 8080,
        ),
      ));
      await _settle();

      expect((await s.discovery.watchPeers().first), isEmpty);
    });

    test('lost event removes the matching peer', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      final observer = s.backend.activeObservers.first;
      observer.emit(_resolved(
        name: 'sharer-a',
        deviceId: 'peer-1',
        displayName: 'A',
      ));
      observer.emit(_resolved(
        name: 'sharer-b',
        deviceId: 'peer-2',
        displayName: 'B',
      ));
      await _settle();
      expect((await s.discovery.watchPeers().first), hasLength(2));

      observer.emit(MdnsEvent(
        kind: MdnsEventKind.lost,
        service: const MdnsService(
          name: 'sharer-a',
          attributes: {'deviceId': 'peer-1'},
        ),
      ));
      await _settle();

      final peers = await s.discovery.watchPeers().first;
      expect(peers.map((p) => p.id), ['peer-2']);
    });
  });

  group('MdnsPeerDiscovery — broadcast spec', () {
    test('uses session-unique mDNS name + TXT name + deviceId attrs',
        () async {
      final s = _setup(selfId: 'my-device', selfName: 'My Phone');
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();

      final spec = s.backend.activeBroadcasters.single.spec;
      expect(spec.name, startsWith('sharer-'));
      expect(spec.name.length, greaterThan('sharer-'.length));
      expect(spec.attributes['deviceId'], 'my-device');
      expect(spec.attributes['name'], 'My Phone');
      expect(spec.type, '_sharer._tcp');
      expect(spec.port, MdnsPeerDiscovery.advertisedPort);
    });

    test('two start/stop cycles produce distinct mDNS names', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();
      final firstName = s.backend.activeBroadcasters.single.spec.name;

      s.trust.add(false);
      await _settle();

      s.trust.add(true);
      await _settle();
      final secondName = s.backend.activeBroadcasters.single.spec.name;

      expect(firstName, isNot(equals(secondName)));
    });
  });

  group('MdnsPeerDiscovery — announcing stream', () {
    test('emits true on enable, false on disable', () async {
      final s = _setup();
      addTearDown(s.discovery.dispose);
      addTearDown(s.trust.close);

      final emissions = <bool>[];
      final sub = s.discovery.watchAnnouncing().listen(emissions.add);

      await s.discovery.start();
      s.trust.add(true);
      await _settle();
      s.trust.add(false);
      await _settle();

      expect(emissions, contains(true));
      expect(emissions.last, isFalse);

      await sub.cancel();
    });
  });
}
