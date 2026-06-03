import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/repositories/peer_cache_repository.dart';

import '../../fakes/fake_mdns_backend.dart';
import '../../fakes/fake_network_source.dart';
import '../../fakes/fake_transfer_service.dart';

/// Returns a canned getById result so the "fresh cached address" condition is
/// deterministic without clock games.
class _FakePeerCache implements PeerCacheRepository {
  _FakePeerCache(this._fresh);
  final Map<String, Peer> _fresh;

  @override
  Future<Peer?> getById(String deviceId, {Duration? freshFor, DateTime? now}) async =>
      _fresh[deviceId];

  @override
  Future<List<Peer>> load() async => const [];
  @override
  Future<void> save(List<Peer> peers) async {}
  @override
  Future<void> upsert(Peer peer) async {}
  @override
  Future<void> remove(String peerId) async {}
  @override
  Future<void> cacheAddress({
    required String deviceId,
    required String host,
    required int port,
    String? displayName,
  }) async {}
}

Peer _peer(String id) => Peer(
      id: id,
      name: id,
      host: '10.0.0.5',
      port: 8080,
      lastSeen: DateTime.utc(2026, 6, 2),
    );

PairedDevice _device(String id) => PairedDevice(
      deviceId: id,
      displayName: id,
      psk: Uint8List(32),
      publicKey: Uint8List(32),
      pairedAt: DateTime.utc(2026, 6, 2),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<Peer> peers,
  required List<PairedDevice> paired,
  required Map<String, Peer> freshCache,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
      networkSourceProvider
          .overrideWith((ref) => FakeNetworkSource(initial: null)),
      transferServiceProvider.overrideWithValue(FakeTransferService(const [])),
      peerCacheProvider.overrideWithValue(_FakePeerCache(freshCache)),
      peersStreamProvider.overrideWith((ref) => Stream.value(peers)),
      pairedDevicesStreamProvider.overrideWith((ref) => Stream.value(paired)),
    ],
    child: const SharerApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('paired peer with a fresh cached address shows "Saved address"',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('a')],
      paired: [_device('a')],
      freshCache: {'a': _peer('a')},
    );
    expect(find.text('Saved address'), findsOneWidget);
  });

  testWidgets('paired peer without a cache entry shows no indicator',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('b')],
      paired: [_device('b')],
      freshCache: const {},
    );
    expect(find.text('Saved address'), findsNothing);
  });

  testWidgets('unpaired peer never shows the indicator even with a cache entry',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('c')],
      paired: const [],
      freshCache: {'c': _peer('c')},
    );
    expect(find.text('Saved address'), findsNothing);
  });
}
