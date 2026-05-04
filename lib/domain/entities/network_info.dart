/// What kind of physical link the device is on. Affects what we can read
/// (Wi-Fi has SSID, Ethernet doesn't) but **not** the trust fingerprint —
/// two interfaces on the same subnet are treated as the same network for
/// trust purposes.
enum NetworkLinkType { wifi, ethernet, unknown }

/// Snapshot of the device's current local-network state. Null overall when
/// no usable connection exists (cellular only, disconnected, etc.).
class NetworkInfo {
  final NetworkLinkType linkType;
  final String? ssid;
  final String? ipv4;

  /// CIDR-style /24 prefix derived from [ipv4], used as the trust key for
  /// the subnet. Null when [ipv4] is unknown.
  final String? subnet;

  const NetworkInfo({
    this.linkType = NetworkLinkType.unknown,
    this.ssid,
    this.ipv4,
    this.subnet,
  });

  /// Stable identifier used to key trusted-network entries. Combines SSID
  /// and subnet so two networks with the same SSID but different subnets
  /// aren't confused, and so an IP change inside the same subnet doesn't
  /// break trust. Link type is **not** part of the fingerprint — a laptop
  /// switching from Wi-Fi to Ethernet on the same subnet stays trusted.
  String get fingerprint => '${ssid ?? ''}|${subnet ?? ''}';

  bool get hasNetwork => ssid != null || ipv4 != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkInfo &&
          runtimeType == other.runtimeType &&
          linkType == other.linkType &&
          ssid == other.ssid &&
          ipv4 == other.ipv4 &&
          subnet == other.subnet;

  @override
  int get hashCode => Object.hash(linkType, ssid, ipv4, subnet);
}
