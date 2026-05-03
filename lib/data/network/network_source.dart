import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart' as ni;

import '../../domain/entities/network_info.dart';

/// Thin platform abstraction over connectivity_plus + network_info_plus so
/// the watcher logic in [NetworkWatcherImpl] can be unit-tested without
/// touching real platform channels.
abstract class NetworkSource {
  /// Fires once per connectivity change. Listeners typically call [read]
  /// in response to sample the new network.
  Stream<void> connectivityChanges();

  /// One-shot snapshot of the current Wi-Fi network. Null when not on Wi-Fi.
  Future<NetworkInfo?> read();
}

class PlatformNetworkSource implements NetworkSource {
  final Connectivity _connectivity;
  final ni.NetworkInfo _wifi;

  PlatformNetworkSource({Connectivity? connectivity, ni.NetworkInfo? wifi})
      : _connectivity = connectivity ?? Connectivity(),
        _wifi = wifi ?? ni.NetworkInfo();

  @override
  Stream<void> connectivityChanges() =>
      _connectivity.onConnectivityChanged.map((_) {});

  @override
  Future<NetworkInfo?> read() async {
    final results = await _connectivity.checkConnectivity();
    if (!results.contains(ConnectivityResult.wifi)) return null;

    final rawSsid = await _wifi.getWifiName();
    final ipv4 = await _wifi.getWifiIP();
    return NetworkInfo(
      ssid: _stripQuotes(rawSsid),
      ipv4: ipv4,
      subnet: _deriveSubnet(ipv4),
    );
  }

  /// SSIDs from network_info_plus are sometimes returned wrapped in quotes
  /// (`"MyHomeWifi"`) on Android. Normalize for consistent fingerprinting.
  static String? _stripQuotes(String? s) {
    if (s == null || s.length < 2) return s;
    if (s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /// `192.168.1.34` → `192.168.1.0/24`. Treats /24 as the trust unit, which
  /// matches typical home routers. Returns null on malformed input.
  static String? _deriveSubnet(String? ipv4) {
    if (ipv4 == null) return null;
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.0/24';
  }
}
