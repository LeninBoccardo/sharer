import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/discovery/bonsoir_mdns_backend.dart';
import '../data/discovery/mdns_backend.dart';
import '../data/discovery/mdns_peer_discovery.dart';
import '../data/identity/device_identity_store.dart';
import '../data/identity/platform_device_name.dart';
import '../data/network/network_source.dart';
import '../data/network/network_watcher_impl.dart';
import '../data/network/trusted_networks_store.dart';
import '../data/notifications/foreground_service_controller.dart';
import '../data/notifications/foreground_service_gateway.dart';
import '../data/notifications/notification_coordinator.dart';
import '../data/notifications/notification_router.dart';
import '../data/notifications/notification_service.dart';
import '../data/notifications/windows_tray_controller.dart';
import '../data/security/forget_service.dart';
import '../data/share/incoming_share_service.dart';
import '../data/security/hmac_verifier.dart';
import '../data/security/pair_invite_client.dart';
import '../data/security/pair_invite_service.dart';
import '../data/security/paired_devices_store.dart';
import '../data/security/pairing_client.dart';
import '../data/security/pairing_service.dart';
import '../data/security/secure_key_value_store.dart';
import '../data/security/tls_key_material.dart';
import '../data/security/tls_key_material_store.dart';
import '../data/storage/downloads_locator.dart';
import '../data/storage/peer_cache_store.dart';
import '../data/transport/http_file_client.dart';
import '../data/transport/http_file_server.dart';
import '../data/transport/transfer_service_impl.dart';
import '../domain/entities/device_identity.dart';
import '../domain/entities/network_info.dart';
import '../domain/entities/pair_invite.dart';
import '../domain/entities/paired_device.dart';
import '../domain/entities/peer.dart';
import '../domain/entities/transfer.dart';
import '../domain/repositories/device_identity_repository.dart';
import '../domain/repositories/network_watcher_repository.dart';
import '../domain/repositories/paired_devices_repository.dart';
import '../domain/repositories/peer_cache_repository.dart';
import '../domain/repositories/peer_discovery_repository.dart';
import '../domain/repositories/transfer_service.dart';
import '../presentation/pairing/invite_controller.dart';
import '../presentation/share/pending_shares_controller.dart';

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
    secure: ref.watch(secureKeyValueStoreProvider),
    defaultName: ref.watch(defaultDeviceNameResolverProvider),
    onMigrationReset: () async {
      // Migrating from the slice 4.1–4.4 UUID identity wipes paired
      // devices — every entry was bound to the old deviceId/PSK that
      // no longer matches anything (per OQ-12 / slice 4.5 plan).
      final paired = ref.read(pairedDevicesRepoProvider);
      for (final d in await paired.getAll()) {
        await paired.remove(d.deviceId);
      }
    },
  );
});

/// Slice 5.1: lazy-initialised store for the device's self-signed TLS
/// keypair + cert. First read on any device generates fresh material
/// and persists the cert to prefs + private key to secure storage.
final tlsKeyMaterialStoreProvider = Provider<TlsKeyMaterialStore>((ref) {
  return TlsKeyMaterialStore(
    ref.watch(sharedPreferencesProvider),
    secure: ref.watch(secureKeyValueStoreProvider),
    onReset: () async {
      // If the TLS material is regenerated (corruption recovery,
      // factory reset), every existing PairedDevice entry has a
      // pinned cert fingerprint that no longer matches — so wipe
      // them. Same posture as the Ed25519-identity migration.
      final paired = ref.read(pairedDevicesRepoProvider);
      for (final d in await paired.getAll()) {
        await paired.remove(d.deviceId);
      }
    },
  );
});

/// FutureProvider for UI consumers — the underlying store generates
/// material lazily on first read.
final tlsKeyMaterialProvider = FutureProvider<TlsKeyMaterial>((ref) {
  return ref.watch(tlsKeyMaterialStoreProvider).get();
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

/// Derived view used by the peer list to badge already-paired peers.
/// Empty when paired devices haven't loaded yet — the tile just shows
/// the unpaired state until then.
final pairedDeviceIdsProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(pairedDevicesStreamProvider).value ?? const [];
  return {for (final d in list) d.deviceId};
});

/// Server-side HMAC validator. The same instance is used for the whole
/// app lifetime so its replay-buffer state survives across requests.
final hmacVerifierProvider = Provider<HmacVerifier>((ref) {
  return HmacVerifier(ref.watch(pairedDevicesRepoProvider));
});

/// Coordinates the pairing handshake on both sides — owns the active
/// offer registry on the initiator, and stores the initiator on the
/// responder once the network round-trip succeeds. Single instance
/// per app session so the offer registry doesn't get cleared between
/// the show-pair screen mounting and the responder's POST arriving.
final pairingServiceProvider = Provider<PairingService>((ref) {
  final svc = PairingService(
    ref.watch(pairedDevicesRepoProvider),
    ref.watch(deviceIdentityRepoProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

final pairingClientProvider = Provider<PairingClient>((ref) {
  final client = PairingClient();
  ref.onDispose(client.close);
  return client;
});

/// Slice 4.6: coordinates the LAN pair-invite handshake. One instance
/// per session — the in-flight registry must outlive the screens that
/// open and close around a given invite.
final pairInviteServiceProvider = Provider<PairInviteService>((ref) {
  final svc = PairInviteService(
    ref.watch(pairedDevicesRepoProvider),
    ref.watch(deviceIdentityRepoProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// Outbound HTTP for /pair-invite + /pair-finalize.
final pairInviteClientProvider = Provider<PairInviteClient>((ref) {
  final client = PairInviteClient();
  ref.onDispose(client.close);
  return client;
});

/// Reactive view of in-flight + completed invites. The fingerprint
/// modal subscribes here to react to status transitions (peer
/// declined, peer matched, expired).
final pairInviteStreamProvider = StreamProvider<PairInvite>((ref) {
  return ref.watch(pairInviteServiceProvider).invites;
});

final inviteControllerProvider = Provider<InviteController>((ref) {
  return InviteController(
    service: ref.watch(pairInviteServiceProvider),
    client: ref.watch(pairInviteClientProvider),
    identityRepo: ref.watch(deviceIdentityRepoProvider),
    tlsStore: ref.watch(tlsKeyMaterialStoreProvider),
    peerCache: ref.watch(peerCacheProvider),
  );
});

/// Slice 5.4: proactive + reactive forget coordinator. One instance per
/// session — owns the peer-forgot-you POST client + the events stream
/// the notification coordinator subscribes to. Reading this provider
/// triggers nothing until [forgetPeer] / [recordRemoteForgot] /
/// [recordReactive401] is called.
final forgetServiceProvider = Provider<ForgetService>((ref) {
  final svc = ForgetService(
    pairedRepo: ref.watch(pairedDevicesRepoProvider),
    peerCache: ref.watch(peerCacheProvider),
    client: ref.watch(pairInviteClientProvider),
    identityRepo: ref.watch(deviceIdentityRepoProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
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

/// Always-on HTTPS server (slice 5.1). Bound for the lifetime of the
/// app; trust transitions only flip whether the pair routes (`/pair`,
/// `/pair-invite`, `/pair-finalize`) accept requests. `/upload` is
/// always reachable but gated by HMAC-from-a-paired-peer — see
/// docs/v1/security.md §5.
final httpFileServerProvider = Provider<HttpFileServer>((ref) {
  final server = HttpFileServer(
    downloads: ref.watch(downloadsLocatorProvider),
    isTrusted: ref.watch(networkWatcherProvider).watchIsTrusted(),
    verifier: ref.watch(hmacVerifierProvider),
    pairing: ref.watch(pairingServiceProvider),
    invite: ref.watch(pairInviteServiceProvider),
    peerCache: ref.watch(peerCacheProvider),
    forget: ref.watch(forgetServiceProvider),
    tlsMaterial: ref.watch(tlsKeyMaterialStoreProvider).get(),
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
    pairedRepo: ref.watch(pairedDevicesRepoProvider),
    peerCache: ref.watch(peerCacheProvider),
    forget: ref.watch(forgetServiceProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

final transfersStreamProvider = StreamProvider<List<Transfer>>((ref) {
  return ref.watch(transferServiceProvider).watchAll();
});

// ----- Notifications (slice 5.2.1) -----

/// Singleton notification platform wrapper. Override in tests with a
/// fake plugin so widget tests don't hit MethodChannels.
final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

/// Coordinator that wires the transfer + invite + trust streams into
/// the notification service. Read once at app boot (see [main]) so it
/// starts listening before any incoming activity can be missed.
final notificationCoordinatorProvider =
    Provider<NotificationCoordinator>((ref) {
  final coord = NotificationCoordinator(
    service: ref.watch(notificationServiceProvider),
    transfers: ref.watch(transferServiceProvider).watchAll(),
    invites: ref.watch(pairInviteServiceProvider).invites,
    isTrusted: ref.watch(networkWatcherProvider).watchIsTrusted(),
    forgetEvents: ref.watch(forgetServiceProvider).events,
  );
  ref.onDispose(coord.dispose);
  coord.start();
  return coord;
});

// ----- Foreground service (slice 5.2.2) -----

/// Production foreground-service gateway. Override with a fake in
/// tests so widget / integration tests don't try to start a real
/// Android service through method channels.
final foregroundServiceGatewayProvider =
    Provider<ForegroundServiceGateway>((ref) {
  return FlutterForegroundServiceGateway();
});

/// Lifecycle controller bound to [pairedDevicesRepoProvider]'s stream.
/// Read once at app boot so the service starts (or doesn't) based on
/// whether there's anyone paired before the user navigates anywhere.
final foregroundServiceControllerProvider =
    Provider<ForegroundServiceController>((ref) {
  final controller = ForegroundServiceController(
    pairedDevices: ref.watch(pairedDevicesRepoProvider).watch(),
    gateway: ref.watch(foregroundServiceGatewayProvider),
  );
  ref.onDispose(controller.dispose);
  controller.start();
  return controller;
});

/// Slice 5.2.3: Windows tray + close-to-tray. Read once at app boot
/// so the close-to-tray prevent flag is set before the first frame
/// renders. No-op on platforms other than Windows; the controller
/// itself does the platform check.
final windowsTrayControllerProvider =
    Provider<WindowsTrayController>((ref) {
  final controller = WindowsTrayController();
  ref.onDispose(controller.dispose);
  controller.start();
  return controller;
});

// ----- OS share-sheet integration (slice 5.5) -----

/// Platform bridge that listens for ACTION_SEND / ACTION_SEND_MULTIPLE
/// intents on Android. No-op on Windows / iOS / Linux for now (Windows
/// Share contract requires MSIX packaging — see incoming_share_service
/// for the deferral note).
final incomingShareServiceProvider = Provider<IncomingShareService>((ref) {
  final svc = IncomingShareService();
  ref.onDispose(svc.dispose);
  return svc;
});

/// Pending files received via the share-sheet, waiting for the user to
/// pick a destination peer. Read once at app boot from main() so the
/// cold-start share is captured before the home screen renders.
final pendingSharesControllerProvider =
    Provider<PendingSharesController>((ref) {
  final controller =
      PendingSharesController(ref.watch(incomingShareServiceProvider));
  ref.onDispose(controller.dispose);
  ref.read(incomingShareServiceProvider).start();
  controller.start();
  return controller;
});

/// Reactive view of the pending-shares state. Home screen watches this
/// to decide whether to show the "share into…" banner + flip the peer
/// tile's tap handler.
final pendingSharesProvider = StreamProvider<PendingShares>((ref) {
  final controller = ref.watch(pendingSharesControllerProvider);
  return Stream.value(controller.state).asyncExpand(
    (initial) async* {
      yield initial;
      yield* controller.stream;
    },
  );
});

/// Slice 5.2.4: dispatches notification taps + action buttons. Reads
/// the cold-start launch details on construction and routes
/// accordingly. Reading this provider also subscribes to the
/// foreground response stream.
final notificationRouterProvider =
    Provider<NotificationRouter>((ref) {
  final tray = ref.watch(windowsTrayControllerProvider);
  final router = NotificationRouter(
    service: ref.watch(notificationServiceProvider),
    inviteController: ref.watch(inviteControllerProvider),
    openFile: (path) async {
      await OpenFilex.open(path);
    },
    showMainWindow: tray.showMainWindow,
  );
  ref.onDispose(router.dispose);
  router.start();
  return router;
});
