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

import '../../fakes/fake_mdns_backend.dart';
import '../../fakes/fake_network_source.dart';
import '../../fakes/fake_transfer_service.dart';

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
  Map<String, Object> prefsSeed = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
      networkSourceProvider
          .overrideWith((ref) => FakeNetworkSource(initial: null)),
      transferServiceProvider.overrideWithValue(FakeTransferService(const [])),
      peersStreamProvider.overrideWith((ref) => Stream.value(peers)),
      pairedDevicesStreamProvider.overrideWith(
          (ref) => Stream.value([for (final p in peers) _device(p.id)])),
    ],
    child: const SharerApp(),
  ));
  await tester.pumpAndSettle();
}

double _y(WidgetTester tester, String name) =>
    tester.getCenter(find.text(name)).dy;

void main() {
  testWidgets('a favorited paired peer sorts to the top of Paired',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('a'), _peer('b'), _peer('c')],
      prefsSeed: {
        'peers.favorites.v1': ['c']
      },
    );

    // c is pinned -> it leads, then discovery order a, b.
    expect(_y(tester, 'c'), lessThan(_y(tester, 'a')));
    expect(_y(tester, 'c'), lessThan(_y(tester, 'b')));
    expect(_y(tester, 'a'), lessThan(_y(tester, 'b')));
  });

  testWidgets('with no favorites the Paired order is unchanged',
      (tester) async {
    await _pump(tester, peers: [_peer('a'), _peer('b'), _peer('c')]);
    expect(_y(tester, 'a'), lessThan(_y(tester, 'b')));
    expect(_y(tester, 'b'), lessThan(_y(tester, 'c')));
  });

  testWidgets('tapping a star pins the peer to the top and fills the star',
      (tester) async {
    await _pump(tester, peers: [_peer('a'), _peer('b')]);
    // Order a, b -> the second star button belongs to b.
    expect(_y(tester, 'a'), lessThan(_y(tester, 'b')));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.star_border).at(1));
    await tester.pumpAndSettle();

    // b is now pinned -> sorts above a, and one star is now filled.
    expect(_y(tester, 'b'), lessThan(_y(tester, 'a')));
    expect(find.byIcon(Icons.star), findsOneWidget);
  });
}
