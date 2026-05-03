/// Snapshot of the device's current Wi-Fi state. Null when no Wi-Fi is
/// available (e.g. cellular only, or disconnected).
class NetworkInfo {
  final String? ssid;
  final String? ipv4;

  /// CIDR-style /24 prefix derived from [ipv4], used as the trust key for the
  /// subnet. Null when [ipv4] is unknown.
  final String? subnet;

  const NetworkInfo({this.ssid, this.ipv4, this.subnet});

  /// Stable identifier used to key trusted-network entries. Combines SSID and
  /// subnet so two networks with the same SSID but different subnets aren't
  /// confused, and so an IP change inside the same subnet doesn't break trust.
  String get fingerprint => '${ssid ?? ''}|${subnet ?? ''}';

  bool get hasWifi => ssid != null || ipv4 != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkInfo &&
          runtimeType == other.runtimeType &&
          ssid == other.ssid &&
          ipv4 == other.ipv4 &&
          subnet == other.subnet;

  @override
  int get hashCode => Object.hash(ssid, ipv4, subnet);
}
