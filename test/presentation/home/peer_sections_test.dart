import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
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
  // Tall enough that the pair-first modal sheet fits without a (test-only)
  // RenderFlex overflow on the default 600px viewport.
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
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
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('partitions peers into Paired and Nearby sections',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('a', 'Alpha'), _peer('b', 'Beta'), _peer('c', 'Gamma')],
      paired: [_device('a'), _device('c')],
    );

    expect(find.text('Paired'), findsOneWidget);
    expect(find.text('Nearby (not paired)'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('hides the Nearby header when every peer is paired',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('a', 'Alpha'), _peer('c', 'Gamma')],
      paired: [_device('a'), _device('c')],
    );

    expect(find.text('Paired'), findsOneWidget);
    expect(find.text('Nearby (not paired)'), findsNothing);
  });

  testWidgets('hides the Paired header when no peer is paired', (tester) async {
    await _pump(
      tester,
      peers: [_peer('b', 'Beta')],
      paired: const [],
    );

    expect(find.text('Nearby (not paired)'), findsOneWidget);
    expect(find.text('Paired'), findsNothing);
  });

  testWidgets('tapping a Nearby (unpaired) tile opens the pair-first sheet',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('b', 'Beta')],
      paired: const [],
    );

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    // The unpaired tap path is preserved: it opens the pair sheet, not a
    // file picker / send.
    expect(find.text('Pair with Beta first'), findsOneWidget);
  });
}
