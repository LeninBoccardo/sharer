import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/discovery/bonsoir_mdns_backend.dart';
import '../data/discovery/mdns_backend.dart';
import '../data/discovery/mdns_peer_discovery.dart';
import '../data/identity/device_identity_store.dart';
import '../data/identity/platform_device_name.dart';
import '../data/network/network_source.dart';
import '../data/network/network_watcher_impl.dart';
import '../data/network/trusted_networks_store.dart';
import '../data/security/paired_devices_store.dart';
import '../data/security/secure_key_value_store.dart';
import '../data/storage/downloads_locator.dart';
import '../data/storage/peer_cache_store.dart';
import '../data/transport/http_file_client.dart';
import '../data/transport/http_file_server.dart';
import '../data/transport/transfer_service_impl.dart';
import '../domain/entities/device_identity.dart';
import '../domain/entities/network_info.dart';
import '../domain/entities/paired_device.dart';
import '../domain/entities/peer.dart';
import '../domain/entities/transfer.dart';
import '../domain/repositories/device_identity_repository.dart';
import '../domain/repositories/network_watcher_repository.dart';
import '../domain/repositories/paired_devices_repository.dart';
import '../domain/repositories/peer_cache_repository.dart';
import '../domain/repositories/peer_discovery_repository.dart';
import '../domain/repositories/transfer_service.dart';

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

/// Production secure key/value store. Override with InMemorySecureKeyValueStore
/// in tests so paired-device tests don't touch the platform Keystore/DPAPI.
final secureKeyValueStoreProvider = Provider<SecureKeyValueStore>((ref) {
  return FlutterSecureStorageAdapter();
});

final pairedDevicesRepoProvider = Provider<PairedDevicesRepository>((ref) {
  final store = PairedDevicesStore(ref.watch(secureKeyValueStoreProvider));
  ref.onDispose(store.dispose);
  return store;
});

final pairedDevicesStreamProvider = StreamProvider<List<PairedDevice>>((ref) {
  return ref.watch(pairedDevicesRepoProvider).watch();
});

/// Production mDNS backend. Override with FakeMdnsBackend in tests so
/// nothing touches real platform sockets.
final mdnsBackendProvider = Provider<MdnsBackend>((ref) {
  return BonsoirMdnsBackend();
});

final peerDiscoveryProvider = Provider<PeerDiscoveryRepository>((ref) {
  final discovery = MdnsPeerDiscovery(
    backend: ref.watch(mdnsBackendProvider),
    identityRepo: ref.watch(deviceIdentityRepoProvider),
    isTrusted: ref.watch(networkWatcherProvider).watchIsTrusted(),
  );
  ref.onDispose(discovery.dispose);
  discovery.start();
  return discovery;
});

final peersStreamProvider = StreamProvider<List<Peer>>((ref) {
  return ref.watch(peerDiscoveryProvider).watchPeers();
});

/// Reactive view of "are we currently broadcasting?". Diagnostics screen
/// surfaces this so the trust gate is observable without grepping logs.
final peerAnnouncingProvider = StreamProvider<bool>((ref) {
  return ref.watch(peerDiscoveryProvider).watchAnnouncing();
});

// ----- Transport (slice 3) -----

final downloadsLocatorProvider = Provider<DownloadsLocator>((ref) {
  return PlatformDownloadsLocator();
});

/// HTTP server gated on trust. Runs only when on a trusted network so
/// that — until pairing+HMAC arrive in slice 4 — only people on a
/// network the user has explicitly trusted can push files to us.
final httpFileServerProvider = Provider<HttpFileServer>((ref) {
  final server = HttpFileServer(
    downloads: ref.watch(downloadsLocatorProvider),
    isTrusted: ref.watch(networkWatcherProvider).watchIsTrusted(),
  );
  ref.onDispose(server.dispose);
  server.start();
  return server;
});

final httpFileClientProvider = Provider<HttpFileClient>((ref) {
  final client = HttpFileClient();
  ref.onDispose(client.close);
  return client;
});

final transferServiceProvider = Provider<TransferService>((ref) {
  final svc = TransferServiceImpl(
    client: ref.watch(httpFileClientProvider),
    server: ref.watch(httpFileServerProvider),
    identityRepo: ref.watch(deviceIdentityRepoProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

final transfersStreamProvider = StreamProvider<List<Transfer>>((ref) {
  return ref.watch(transferServiceProvider).watchAll();
});
