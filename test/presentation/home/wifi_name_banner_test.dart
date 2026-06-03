import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/network_info.dart';
import 'package:sharer/domain/repositories/wifi_name_permission.dart';
import 'package:sharer/presentation/home/wifi_name_banner.dart';

import '../../fakes/fake_wifi_name_permission.dart';

NetworkInfo _unnamedWifi() => const NetworkInfo(
      linkType: NetworkLinkType.wifi,
      ipv4: '192.168.68.5',
      subnet: '192.168.68.0/24',
    );

Future<void> _pump(
  WidgetTester tester, {
  required NetworkInfo? network,
  required FakeWifiNamePermission permission,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentNetworkProvider.overrideWith((ref) => Stream.value(network)),
        wifiNamePermissionProvider.overrideWithValue(permission),
      ],
      child: const MaterialApp(
        home: Scaffold(body: WifiNameBanner()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows on an unnamed Wi-Fi with an Allow action', (tester) async {
    await _pump(
      tester,
      network: _unnamedWifi(),
      permission: FakeWifiNamePermission(),
    );
    expect(find.text('Wi-Fi name hidden'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('hidden once the SSID is readable', (tester) async {
    await _pump(
      tester,
      network: const NetworkInfo(
        linkType: NetworkLinkType.wifi,
        ssid: 'Home',
        subnet: '192.168.68.0/24',
      ),
      permission: FakeWifiNamePermission(),
    );
    expect(find.text('Wi-Fi name hidden'), findsNothing);
  });

  testWidgets('hidden on Ethernet (legitimately nameless)', (tester) async {
    await _pump(
      tester,
      network: const NetworkInfo(
        linkType: NetworkLinkType.ethernet,
        ipv4: '10.0.0.5',
        subnet: '10.0.0.0/24',
      ),
      permission: FakeWifiNamePermission(),
    );
    expect(find.text('Wi-Fi name hidden'), findsNothing);
  });

  testWidgets('Allow requests the permission; a denial leaves it requestable',
      (tester) async {
    final permission = FakeWifiNamePermission(
      requestResult: WifiNamePermissionStatus.denied,
    );
    await _pump(tester, network: _unnamedWifi(), permission: permission);

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(permission.requestCount, 1);
    expect(permission.openSettingsCount, 0);
  });

  testWidgets('a permanent denial deep-links to settings', (tester) async {
    final permission = FakeWifiNamePermission(
      requestResult: WifiNamePermissionStatus.permanentlyDenied,
    );
    await _pump(tester, network: _unnamedWifi(), permission: permission);

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(permission.requestCount, 1);
    expect(permission.openSettingsCount, 1);
  });

  testWidgets('Not now dismisses the banner for the session', (tester) async {
    await _pump(
      tester,
      network: _unnamedWifi(),
      permission: FakeWifiNamePermission(),
    );
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi name hidden'), findsNothing);
  });

  testWidgets('desktop (no runtime request) shows Open settings', (tester) async {
    await _pump(
      tester,
      network: _unnamedWifi(),
      permission: FakeWifiNamePermission(supportsRuntimeRequest: false),
    );
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
  });
}
