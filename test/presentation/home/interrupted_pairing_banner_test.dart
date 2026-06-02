import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/data/security/interrupted_pairing_detector.dart';
import 'package:sharer/presentation/home/interrupted_pairing_banner.dart';
import 'package:sharer/presentation/pairing/devices_screen.dart';

import '../../fakes/fake_secure_key_value_store.dart';

const _marker = InterruptedPairing(
  inviteId: 'i1',
  peerName: 'Realme',
  peerId: 'realme',
);

Future<void> _pump(WidgetTester tester, InterruptedPairing? marker) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        interruptedPairingProvider.overrideWith((ref) => marker),
        // DevicesScreen (reached via Re-pair) watches pairedDevicesStream ->
        // a secure store; fake it so no platform channel is touched.
        secureKeyValueStoreProvider
            .overrideWithValue(FakeSecureKeyValueStore()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: InterruptedPairingBanner()),
      ),
    ),
  );
  await tester.pump(); // let the FutureProvider resolve
}

void main() {
  testWidgets('shows the prompt with the peer name when a marker is present',
      (tester) async {
    await _pump(tester, _marker);
    expect(find.text('Previous pairing was interrupted'), findsOneWidget);
    expect(find.textContaining('Realme'), findsOneWidget);
  });

  testWidgets('renders nothing when there is no interrupted marker',
      (tester) async {
    await _pump(tester, null);
    expect(find.text('Previous pairing was interrupted'), findsNothing);
    expect(find.byType(SizedBox), findsWidgets); // the shrink
  });

  testWidgets('Dismiss hides the banner', (tester) async {
    await _pump(tester, _marker);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Previous pairing was interrupted'), findsNothing);
  });

  testWidgets('Re-pair hides the banner and routes to Devices',
      (tester) async {
    await _pump(tester, _marker);
    await tester.tap(find.text('Re-pair'));
    await tester.pumpAndSettle();
    expect(find.byType(DevicesScreen), findsOneWidget);
    expect(find.text('Previous pairing was interrupted'), findsNothing);
  });
}
