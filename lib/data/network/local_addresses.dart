import 'dart:io';

/// All non-loopback, non-link-local IPv4 addresses bound to physical
/// interfaces on this device. Used by the pairing flow to enumerate
/// candidate endpoints — when the PC has both a wired (e.g. 10.5.0.2)
/// and a wireless (e.g. 192.168.68.57) interface, we don't know in
/// advance which one the responder can reach, so we expose all of them
/// in the QR and let the responder pick the first that connects.
///
/// The `currentNetworkProvider` returns a single IP for fingerprinting
/// the trusted network — that's the wrong shape for pairing because
/// it picks just one interface.
Future<List<String>> localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
    includeLoopback: false,
  );
  final out = <String>[];
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      if (addr.isLoopback) continue;
      out.add(addr.address);
    }
  }
  return prioritizeRealLanIpv4(out);
}

/// Audit #37: stably reorders [addresses] so addresses that look like they
/// belong to a host-local virtual adapter (Hyper-V Default Switch, WSL2,
/// Docker) sink to the END of the list, while real LAN IPs stay at the
/// front in their original order. We never DROP an address: on some hosts
/// the only reachable interface is one of these ranges, so the responder
/// must still be able to fall through to it. The responder in the pairing
/// flow tries endpoints in order and keeps the first that connects, so
/// front-loading real LAN IPs avoids burning a connect-timeout on an
/// unreachable virtual IP first.
///
/// Pure + synchronous so it can be unit-tested without sockets.
List<String> prioritizeRealLanIpv4(List<String> addresses) {
  final real = <String>[];
  final virtual = <String>[];
  for (final ip in addresses) {
    (_looksVirtualIpv4(ip) ? virtual : real).add(ip);
  }
  return [...real, ...virtual];
}

/// Heuristic: does [ip] fall in a range commonly handed out by host-local
/// virtual adapters rather than a physical home/office LAN?
///
/// - 172.16.0.0/12 (172.16-31.x.x): Docker's default bridge (172.17.x.x),
///   WSL2 (172.x), and assorted container nets. Rare on real home routers,
///   which overwhelmingly use 192.168.x or 10.x.
/// - 192.168.137.0/24: the legacy Windows Internet-Connection-Sharing /
///   Hyper-V Default Switch host net.
///
/// Anything we can't classify (incl. all other 192.168.x and 10.x) is
/// treated as real and kept ahead of these.
bool _looksVirtualIpv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  final c = int.tryParse(parts[2]);
  if (a == null || b == null || c == null) return false;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168 && c == 137) return true;
  return false;
}
