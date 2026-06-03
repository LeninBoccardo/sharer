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

Peer _peer(String id, String name) => Peer(
      id: id,
      name: name,
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
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
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
      peersStreamProvider.overrideWith((ref) => Stream.value(peers)),
      pairedDevicesStreamProvider.overrideWith((ref) => Stream.value(paired)),
    ],
    child: const SharerApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('paired tile carries a Paired label + verified icon (not color)',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, peers: [_peer('a', 'Alpha')], paired: [_device('a')]);

    expect(find.bySemanticsLabel(RegExp('Paired')), findsWidgets);
    expect(find.byIcon(Icons.verified_user), findsOneWidget);

    handle.dispose();
  });

  testWidgets('unpaired tile carries a Not paired label + open-lock icon',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, peers: [_peer('b', 'Beta')], paired: const []);

    expect(find.bySemanticsLabel(RegExp('Not paired')), findsWidgets);
    expect(find.byIcon(Icons.verified_user), findsNothing);
    expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);

    handle.dispose();
  });
}
