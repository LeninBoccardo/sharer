import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/domain/entities/network_info.dart';

void main() {
  group('NetworkInfo', () {
    test('hasNetwork is true when either ssid or ipv4 is set', () {
      expect(const NetworkInfo().hasNetwork, isFalse);
      expect(const NetworkInfo(ssid: 'Home').hasNetwork, isTrue);
      expect(const NetworkInfo(ipv4: '192.168.1.5').hasNetwork, isTrue);
    });

    test('fingerprint is stable across link types on the same subnet', () {
      const wifi = NetworkInfo(
        linkType: NetworkLinkType.wifi,
        ssid: 'Home',
        ipv4: '192.168.1.10',
        subnet: '192.168.1.0/24',
      );
      const ethernet = NetworkInfo(
        linkType: NetworkLinkType.ethernet,
        ssid: 'Home',
        ipv4: '192.168.1.20',
        subnet: '192.168.1.0/24',
      );
      // Different ipv4, different link, same SSID + subnet → same fingerprint.
      expect(wifi.fingerprint, equals(ethernet.fingerprint));
    });

    test('ethernet without SSID still produces a fingerprint keyed by subnet',
        () {
      const eth = NetworkInfo(
        linkType: NetworkLinkType.ethernet,
        ipv4: '10.0.0.5',
        subnet: '10.0.0.0/24',
      );
      expect(eth.fingerprint, '|10.0.0.0/24');
      expect(eth.hasNetwork, isTrue);
    });

    test('different subnets produce different fingerprints', () {
      const a = NetworkInfo(ssid: 'X', subnet: '192.168.1.0/24');
      const b = NetworkInfo(ssid: 'X', subnet: '192.168.2.0/24');
      expect(a.fingerprint, isNot(equals(b.fingerprint)));
    });
  });
}
