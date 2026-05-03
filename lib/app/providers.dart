import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/discovery/mdns_peer_discovery.dart';
import '../data/identity/device_identity_store.dart';
import '../data/identity/platform_device_name.dart';
import '../data/network/network_source.dart';
import '../data/network/network_watcher_impl.dart';
import '../data/network/trusted_networks_store.dart';
import '../data/storage/peer_cache_store.dart';
import '../domain/entities/device_identity.dart';
import '../domain/entities/network_info.dart';
import '../domain/entities/peer.dart';
import '../domain/repositories/device_identity_repository.dart';
import '../domain/repositories/network_watcher_repository.dart';
import '../domain/repositories/peer_cache_repository.dart';
import '../domain/repositories/peer_discovery_repository.dart';

/// Composition root: every cross-layer binding is declared here so that
/// presentation code never reaches into `data/` directly. To swap an impl
/// (e.g. for tests), override the relevant provider — no UI changes needed.

/// Overridden in `main()` once SharedPreferences has loaded. Tests should
/// supply their own override via `SharedPreferences.setMockInitialValues({})`
/// + `getInstance()` and override here.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()/tests',
  );
});

/// Per-platform default device-name resolver. Override in tests with a
/// fixed string so DeviceIdentityStore tests don't touch device_info_plus.
final defaultDeviceNameResolverProvider =
    Provider<DefaultDeviceNameResolver>((ref) => readPlatformDeviceName);

final deviceIdentityRepoProvider = Provider<DeviceIdentityRepository>((ref) {
  return DeviceIdentityStore(
    ref.watch(sharedPreferencesProvider),
    defaultName: ref.watch(defaultDeviceNameResolverProvider),
  );
});

/// Convenience FutureProvider for UI consumers that want the resolved
/// identity (the repo's get() is async on first call).
final deviceIdentityProvider = FutureProvider<DeviceIdentity>((ref) {
  return ref.watch(deviceIdentityRepoProvider).get();
});

final trustedNetworksStoreProvider = Provider<TrustedNetworksStore>((ref) {
  return TrustedNetworksStore(ref.watch(sharedPreferencesProvider));
});

/// Production network source. Override with a fake in tests / when running
/// the app on a platform without Wi-Fi APIs (e.g. headless CI).
final networkSourceProvider = Provider<NetworkSource>((ref) {
  return PlatformNetworkSource();
});

final networkWatcherProvider = Provider<NetworkWatcherRepository>((ref) {
  final watcher = NetworkWatcherImpl(
    ref.watch(networkSourceProvider),
    ref.watch(trustedNetworksStoreProvider),
  );
  ref.onDispose(watcher.dispose);
  return watcher;
});

final currentNetworkProvider = StreamProvider<NetworkInfo?>((ref) {
  return ref.watch(networkWatcherProvider).watch();
});

final isOnTrustedNetworkProvider = StreamProvider<bool>((ref) {
  return ref.watch(networkWatcherProvider).watchIsTrusted();
});

final trustedNetworksProvider = StreamProvider<Set<String>>((ref) {
  return ref.watch(networkWatcherProvider).watchTrusted();
});

final peerCacheProvider = Provider<PeerCacheRepository>((ref) {
  return PeerCacheStore(ref.watch(sharedPreferencesProvider));
});

final peerDiscoveryProvider = Provider<PeerDiscoveryRepository>((ref) {
  final discovery = MdnsPeerDiscovery(
    identityRepo: ref.watch(deviceIdentityRepoProvider),
    shouldAnnounce: ref.watch(networkWatcherProvider).watchIsTrusted(),
  );
  ref.onDispose(discovery.dispose);
  discovery.start();
  return discovery;
});

final peersStreamProvider = StreamProvider<List<Peer>>((ref) {
  return ref.watch(peerDiscoveryProvider).watchPeers();
});
