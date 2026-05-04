import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';

import 'fakes/fake_mdns_backend.dart';
import 'fakes/fake_network_source.dart';

void main() {
  testWidgets('Home screen renders title and empty state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          // Avoid spinning up real mDNS sockets in widget tests.
          mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
          // No Wi-Fi → trust never fires → discovery stays silent →
          // quiet-mode banner stays hidden.
          networkSourceProvider
              .overrideWith((ref) => FakeNetworkSource(initial: null)),
        ],
        child: const SharerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sharer'), findsOneWidget);
    expect(find.text('Nearby devices'), findsOneWidget);
    expect(find.text('No devices found yet'), findsOneWidget);
    expect(find.byIcon(Icons.devices_other), findsOneWidget);
    expect(find.text('Trust'), findsNothing);
  });
}
