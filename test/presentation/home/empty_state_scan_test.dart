import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/repositories/peer_discovery_repository.dart';

import '../../fakes/fake_network_source.dart';
import '../../fakes/fake_transfer_service.dart';

/// Discovery fake with no peers (so the empty state renders) that records
/// the re-announce burst refreshDiscovery() fires.
class _RecordingDiscovery implements PeerDiscoveryRepository {
  int refreshCount = 0;

  @override
  Future<void> refreshAnnouncement() async => refreshCount++;

  @override
  Stream<List<Peer>> watchPeers() => Stream.value(const []);

  @override
  Stream<bool> watchAnnouncing() => Stream.value(false);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets(
      'empty state shows a Scan button that fires the discovery burst once',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final discovery = _RecordingDiscovery();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          peerDiscoveryProvider.overrideWithValue(discovery),
          networkSourceProvider
              .overrideWith((ref) => FakeNetworkSource(initial: null)),
          transferServiceProvider
              .overrideWithValue(FakeTransferService(const [])),
        ],
        child: const SharerApp(),
      ),
    );
    await tester.pump();

    expect(
        find.widgetWithText(FilledButton, 'Scan for new peers'), findsOneWidget);
    expect(discovery.refreshCount, 0);

    // Tap -> spinner + disabled, and the burst fires exactly once.
    await tester.tap(find.widgetWithText(FilledButton, 'Scan for new peers'));
    await tester.pump();
    expect(find.text('Scanning…'), findsOneWidget);
    // Let refreshDiscovery's recheck + refreshAnnouncement futures resolve.
    await tester.pump();
    await tester.pump();
    expect(discovery.refreshCount, 1);

    // Spinner clears after the transient window (NOT pumpAndSettle -- the
    // CircularProgressIndicator animates forever).
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
        find.widgetWithText(FilledButton, 'Scan for new peers'), findsOneWidget);
    expect(find.text('Scanning…'), findsNothing);
  });
}
