import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/network/network_source.dart';

void main() {
  group('PlatformNetworkSource.deriveSubnet', () {
    test('derives the /24 network address from a host IP', () {
      expect(
        PlatformNetworkSource.deriveSubnet('192.168.1.34'),
        '192.168.1.0/24',
      );
      expect(
        PlatformNetworkSource.deriveSubnet('10.0.0.5'),
        '10.0.0.0/24',
      );
    });

    test('returns null for null or malformed input', () {
      expect(PlatformNetworkSource.deriveSubnet(null), isNull);
      expect(PlatformNetworkSource.deriveSubnet(''), isNull);
      expect(PlatformNetworkSource.deriveSubnet('192.168.1'), isNull);
      expect(PlatformNetworkSource.deriveSubnet('1.2.3.4.5'), isNull);
    });

    test(
        'v1 limitation (audit #36): prefix is always /24 regardless of the real '
        'class — locks in the documented behaviour so a future netmask-aware '
        'change cannot silently alter trust fingerprints', () {
      // A 10.x host that in reality is on a /16 still buckets to /24.
      expect(
        PlatformNetworkSource.deriveSubnet('10.5.99.7'),
        '10.5.99.0/24',
      );
      // A 172.16.x host (commonly /16) still buckets to /24.
      expect(
        PlatformNetworkSource.deriveSubnet('172.16.40.200'),
        '172.16.40.0/24',
      );
    });
  });
}
