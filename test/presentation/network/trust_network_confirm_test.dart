import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/network_info.dart';
import 'package:sharer/domain/repositories/network_watcher_repository.dart';
import 'package:sharer/presentation/network/trust_network_action.dart';

/// Records trust() calls; everything else is an inert no-op.
class _RecordingWatcher implements NetworkWatcherRepository {
  final List<NetworkInfo> trusted = [];

  @override
  Future<void> trust(NetworkInfo info) async => trusted.add(info);

  @override
  Future<NetworkInfo?> current() async => null;
  @override
  Stream<NetworkInfo?> watch() => const Stream.empty();
  @override
  Stream<bool> watchIsTrusted() => const Stream.empty();
  @override
  Stream<Set<String>> watchTrusted() => const Stream.empty();
  @override
  Future<void> untrust(NetworkInfo info) async {}
  @override
  Future<void> untrustFingerprint(String fingerprint) async {}
}

const _unnamed = NetworkInfo(
  linkType: NetworkLinkType.wifi,
  ipv4: '192.168.68.5',
  subnet: '192.168.68.0/24',
);
const _named = NetworkInfo(
  linkType: NetworkLinkType.wifi,
  ssid: 'Home',
  subnet: '192.168.68.0/24',
);

Future<_RecordingWatcher> _pumpButton(
  WidgetTester tester,
  NetworkInfo network,
) async {
  final watcher = _RecordingWatcher();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [networkWatcherProvider.overrideWithValue(watcher)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => trustNetworkWithConfirm(context, ref, network),
              child: const Text('Trust'),
            ),
          ),
        ),
      ),
    ),
  );
  return watcher;
}

void main() {
  testWidgets('a named Wi-Fi trusts directly, no dialog', (tester) async {
    final watcher = await _pumpButton(tester, _named);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();

    expect(find.text('Trust this network?'), findsNothing);
    expect(watcher.trusted, hasLength(1));
  });

  testWidgets('a no-SSID Wi-Fi confirms before trusting; Trust anyway commits',
      (tester) async {
    final watcher = await _pumpButton(tester, _unnamed);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();

    expect(find.text('Trust this network?'), findsOneWidget);
    expect(watcher.trusted, isEmpty); // not yet

    await tester.tap(find.text('Trust anyway'));
    await tester.pumpAndSettle();
    expect(watcher.trusted, hasLength(1));
  });

  testWidgets('a no-SSID Wi-Fi Cancel does not trust', (tester) async {
    final watcher = await _pumpButton(tester, _unnamed);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Trust this network?'), findsNothing);
    expect(watcher.trusted, isEmpty);
  });
}
