import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/network/local_addresses.dart';

void main() {
  group('prioritizeRealLanIpv4 (audit #37)', () {
    test('pushes a Hyper-V/Docker 172.x IP behind a real Wi-Fi IP', () {
      // Realistic PC ordering: NetworkInterface.list often returns the
      // virtual adapter first.
      final ordered = prioritizeRealLanIpv4(['172.17.0.1', '192.168.68.57']);
      expect(ordered, ['192.168.68.57', '172.17.0.1']);
    });

    test('pushes the Hyper-V Default Switch 192.168.137.x IP to the end', () {
      final ordered =
          prioritizeRealLanIpv4(['192.168.137.1', '192.168.1.34']);
      expect(ordered, ['192.168.1.34', '192.168.137.1']);
    });

    test('never drops addresses (virtual-only host still exposes its IP)', () {
      final ordered = prioritizeRealLanIpv4(['172.20.0.5']);
      expect(ordered, ['172.20.0.5']);
    });

    test('keeps real LAN IPs in their original relative order', () {
      final ordered = prioritizeRealLanIpv4([
        '10.5.0.2',
        '172.18.0.1',
        '192.168.68.57',
      ]);
      expect(ordered, ['10.5.0.2', '192.168.68.57', '172.18.0.1']);
    });

    test('keeps multiple virtual IPs in their original relative order', () {
      final ordered = prioritizeRealLanIpv4([
        '172.17.0.1',
        '192.168.1.34',
        '172.20.0.1',
      ]);
      expect(ordered, ['192.168.1.34', '172.17.0.1', '172.20.0.1']);
    });

    test('10.x and ordinary 192.168.x are treated as real LAN', () {
      final ordered = prioritizeRealLanIpv4(['10.0.0.4', '192.168.0.9']);
      expect(ordered, ['10.0.0.4', '192.168.0.9']);
    });

    test('boundary: 172.15.x and 172.32.x are real, 172.16/172.31 virtual',
        () {
      final ordered = prioritizeRealLanIpv4([
        '172.16.0.1',
        '172.15.0.1',
        '172.31.0.1',
        '172.32.0.1',
      ]);
      expect(ordered, ['172.15.0.1', '172.32.0.1', '172.16.0.1', '172.31.0.1']);
    });

    test('empty input returns empty list', () {
      expect(prioritizeRealLanIpv4(const []), isEmpty);
    });
  });
}
