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
  return out;
}
