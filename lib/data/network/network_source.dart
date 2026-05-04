import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart' as ni;

import '../../domain/entities/network_info.dart';

/// Thin platform abstraction over connectivity_plus + network_info_plus +
/// dart:io NetworkInterface so the watcher logic in [NetworkWatcherImpl]
/// can be unit-tested without touching real platform channels.
abstract class NetworkSource {
  /// Fires once per connectivity change. Listeners typically call [read]
  /// in response to sample the new network.
  Stream<void> connectivityChanges();

  /// One-shot snapshot of the current local network. Null when neither
  /// Wi-Fi nor Ethernet is available.
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

    if (results.contains(ConnectivityResult.wifi)) {
      final rawSsid = await _wifi.getWifiName();
      final ipv4 = await _wifi.getWifiIP();
      return NetworkInfo(
        linkType: NetworkLinkType.wifi,
        ssid: _stripQuotes(rawSsid),
        ipv4: ipv4,
        subnet: deriveSubnet(ipv4),
      );
    }

    if (results.contains(ConnectivityResult.ethernet)) {
      final ipv4 = await _readEthernetIpv4();
      return NetworkInfo(
        linkType: NetworkLinkType.ethernet,
        ipv4: ipv4,
        subnet: deriveSubnet(ipv4),
      );
    }

    return null;
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
  static String? deriveSubnet(String? ipv4) {
    if (ipv4 == null) return null;
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.0/24';
  }

  /// Picks the device's primary IPv4 address from the OS interface list.
  /// Used when on Ethernet (network_info_plus is Wi-Fi-only). Prefers
  /// addresses in the standard private ranges to skip virtual adapters
  /// (Hyper-V, WSL, Docker) that often have non-routable IPs.
  static Future<String?> _readEthernetIpv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      String? fallback;
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          final s = addr.address;
          if (_isPrivateIpv4(s)) return s;
          fallback ??= s;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  static bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }
}
