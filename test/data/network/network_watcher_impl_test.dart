import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/network/network_watcher_impl.dart';
import 'package:sharer/data/network/trusted_networks_store.dart';
import 'package:sharer/domain/entities/network_info.dart';

import '../../fakes/fake_network_source.dart';

void main() {
  late SharedPreferences prefs;
  late TrustedNetworksStore trusted;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    trusted = TrustedNetworksStore(prefs);
  });

  group('NetworkWatcherImpl', () {
    test('watch() seeds null then emits new networks on change', () async {
      final source = FakeNetworkSource();
      final watcher = NetworkWatcherImpl(source, trusted);
      addTearDown(watcher.dispose);

      final emissions = <NetworkInfo?>[];
      final sub = watcher.watch().listen(emissions.add);

      // Allow the constructor's initial read to settle.
      await Future<void>.delayed(Duration.zero);
      source.emit(const NetworkInfo(
        ssid: 'Home',
        ipv4: '192.168.1.10',
        subnet: '192.168.1.0/24',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(emissions, contains(null));
      expect(
        emissions.whereType<NetworkInfo>().map((n) => n.ssid),
        contains('Home'),
      );

      await sub.cancel();
    });

    test('isTrusted is false on unknown network, true after trust()', () async {
      final home = const NetworkInfo(
        ssid: 'Home',
        ipv4: '192.168.1.10',
        subnet: '192.168.1.0/24',
      );
      final source = FakeNetworkSource(initial: home);
      final watcher = NetworkWatcherImpl(source, trusted);
      addTearDown(watcher.dispose);

      // Let the initial read populate _latest.
      await Future<void>.delayed(Duration.zero);

      final trustedEmissions = <bool>[];
      final sub = watcher.watchIsTrusted().listen(trustedEmissions.add);

      await Future<void>.delayed(Duration.zero);
      expect(trustedEmissions.last, isFalse);

      await watcher.trust(home);
      await Future<void>.delayed(Duration.zero);
      expect(trustedEmissions.last, isTrue);

      await watcher.untrust(home);
      await Future<void>.delayed(Duration.zero);
      expect(trustedEmissions.last, isFalse);

      await sub.cancel();
    });

    test('watchTrusted emits the set after trust/untrust', () async {
      final home = const NetworkInfo(
        ssid: 'Home',
        ipv4: '192.168.1.10',
        subnet: '192.168.1.0/24',
      );
      final cafe = const NetworkInfo(
        ssid: 'Cafe',
        ipv4: '10.0.0.5',
        subnet: '10.0.0.0/24',
      );
      final source = FakeNetworkSource(initial: home);
      final watcher = NetworkWatcherImpl(source, trusted);
      addTearDown(watcher.dispose);
      await Future<void>.delayed(Duration.zero);

      final emissions = <Set<String>>[];
      final sub = watcher.watchTrusted().listen((s) => emissions.add(s));

      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await watcher.trust(home);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, equals({home.fingerprint}));

      await watcher.trust(cafe);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, equals({home.fingerprint, cafe.fingerprint}));

      await watcher.untrustFingerprint(home.fingerprint);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, equals({cafe.fingerprint}));

      await sub.cancel();
    });

    test('disconnecting Wi-Fi flips isTrusted back to false', () async {
      final home = const NetworkInfo(
        ssid: 'Home',
        ipv4: '192.168.1.10',
        subnet: '192.168.1.0/24',
      );
      await trusted.add(home.fingerprint);

      final source = FakeNetworkSource(initial: home);
      final watcher = NetworkWatcherImpl(source, trusted);
      addTearDown(watcher.dispose);
      await Future<void>.delayed(Duration.zero);

      final emissions = <bool>[];
      final sub = watcher.watchIsTrusted().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isTrue);

      source.emit(null);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isFalse);

      await sub.cancel();
    });
  });
}
