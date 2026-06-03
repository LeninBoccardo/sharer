import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/repositories/wifi_name_permission.dart';

/// Shared "make the Wi-Fi name readable" action, called by both the home
/// "Wi-Fi name hidden" banner and the diagnostics current-network card so the
/// request → re-sample flow lives in exactly one place.
///
/// Android/iOS: pops the location dialog. On a fresh grant, re-samples the
/// network watcher ([refreshDiscovery]) so a now-readable SSID clears the
/// prompt; on a permanent denial, deep-links to app settings.
/// Desktop: [WifiNamePermission.request] already opened OS location settings,
/// so there is nothing more to do here.
Future<void> promptForWifiName(WidgetRef ref) async {
  final permission = ref.read(wifiNamePermissionProvider);
  final result = await permission.request();
  switch (result) {
    case WifiNamePermissionStatus.granted:
      await refreshDiscovery(ref);
    case WifiNamePermissionStatus.permanentlyDenied:
      await permission.openSettings();
    case WifiNamePermissionStatus.denied:
    case WifiNamePermissionStatus.unsupported:
      // denied: the user can tap again. unsupported (desktop): request()
      // already opened the OS location settings.
      break;
  }
}
