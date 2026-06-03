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
  ///
  /// The prefix is always /24 in v1 (see
  /// `PlatformNetworkSource.deriveSubnet`, audit #36): non-/24 networks are
  /// bucketed at /24 granularity because no reliable netmask is available on
  /// all platforms and changing the prefix would break stored trust
  /// [fingerprint]s.
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

  /// True on a Wi-Fi link whose SSID could not be read (null or empty).
  ///
  /// This is one signal serving two purposes:
  ///   * **UX** — the "Wi-Fi name hidden" prompt that asks for the location
  ///     permission (Android) or to enable OS location (Windows), since the
  ///     SSID read is gated behind it.
  ///   * **Trust (#17)** — a "weak fingerprint" marker. With no SSID the
  ///     [fingerprint] degenerates to `|subnet`, so the network can only be
  ///     recognised by its /24 IP range — a different Wi-Fi handing out the
  ///     same range would match identically. Trusting such a network is a
  ///     deliberate, subnet-only (spoofable) choice, so the UI gates it
  ///     behind a confirmation and flags the stored entry.
  bool get isUnnamedWifi =>
      linkType == NetworkLinkType.wifi && (ssid == null || ssid!.isEmpty);

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
