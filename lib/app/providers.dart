import 'dart:io' show Platform, Process;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
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
import '../data/security/in_flight_invite_store.dart';
import '../data/security/interrupted_pairing_detector.dart';
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
import '../data/system/brightness_controller.dart';
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
import '../data/security/invite_controller.dart';
import '../presentation/share/pending_shares_controller.dart';
import '../presentation/transfers/received_file_actions.dart';

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
///
/// Audit #43: this returns a *fresh* `Set` instance on every emit of
/// [pairedDevicesStreamProvider], and `Set` has identity-based equality.
/// Riverpod gates listener notifications on `previous != next`, so a
/// raw `ref.watch(pairedDeviceIdsProvider)` rebuilds the consumer on
/// every paired-devices emit even when the membership is unchanged —
/// once per peer tile, on the hot share path. Consumers MUST therefore
/// `.select` the scalar they actually need (e.g.
/// `pairedDeviceIdsProvider.select((ids) => ids.contains(peerId))`):
/// the selected `bool` has value-equality, so identical-content emits no
/// longer trigger a widget rebuild. The selector itself stays O(1).
final pairedDeviceIdsProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(pairedDevicesStreamProvider).value ?? const [];
  return {for (final d in list) d.deviceId};
});

/// Server-side HMAC validator. The same instance is used for the whole
/// app lifetime so its replay-buffer state survives across requests.
final hmacVerifierProvider = Provider<HmacVerifier>((ref) {
  return HmacVerifier(
    ref.watch(pairedDevicesRepoProvider),
    // Audit #30: the verifier reconstructs the HMAC canonical with this
    // device's own id as the recipient field. Resolved once (the repo
    // caches the identity after first read) and shared for the app
    // lifetime, matching the single-instance verifier.
    localDeviceId:
        ref.watch(deviceIdentityRepoProvider).get().then((i) => i.id),
  );
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

/// Slice 5.2.4.2: persistent mailbox of in-flight invites used by the
/// background notification isolate when the user taps Decline on a
/// pair-invite while the main isolate is dead.
final inFlightInviteStoreProvider = Provider<InFlightInviteStore>((ref) {
  return InFlightInviteStore(ref.watch(secureKeyValueStoreProvider));
});

/// Phase 4 doc-gap: detects a responder-side pair handshake left in the
/// persisted mailbox by a crash/kill mid-confirm (architecture.md transport
/// rule #4 / ux.md pairing rule #4).
final interruptedPairingDetectorProvider =
    Provider<InterruptedPairingDetector>((ref) {
  return InterruptedPairingDetector(ref.watch(inFlightInviteStoreProvider));
});

/// One-shot: resolves to the leftover interrupted handshake (if any) and
/// PURGES the marker as a side effect, so the prompt shows exactly once.
/// FutureProvider memoizes the result for the container lifetime — no
/// re-detection within a session, so a new invite saved later this run
/// never re-raises the banner. Do NOT ref.invalidate it (it would re-read
/// an already-empty mailbox and return null — safe, but pointless).
final interruptedPairingProvider = FutureProvider<InterruptedPairing?>((ref) {
  return ref
      .watch(interruptedPairingDetectorProvider)
      .detectAndConsume(DateTime.now());
});

/// Slice 4.6: coordinates the LAN pair-invite handshake. One instance
/// per session — the in-flight registry must outlive the screens that
/// open and close around a given invite.
final pairInviteServiceProvider = Provider<PairInviteService>((ref) {
  final svc = PairInviteService(
    ref.watch(pairedDevicesRepoProvider),
    ref.watch(deviceIdentityRepoProvider),
    mailbox: ref.watch(inFlightInviteStoreProvider),
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
  // Audit #21: browsers have no raw sockets and no mDNS, so there is
  // nothing for discovery to do on web. Skip start() so we never wire the
  // trust-stream subscription (and never touch the bonsoir backend).
  // kIsWeb is a compile-time const — false on every native platform, so
  // this branch folds out and native stays byte-identical. The provider
  // still returns the (idle) discovery object so peersStreamProvider /
  // peerAnnouncingProvider resolve and emit their empty seeds.
  if (!kIsWeb) discovery.start();
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

/// Single entry point for an event-driven discovery burst: re-sample the
/// network (a resume can land us back on a trusted AP after roaming / a
/// DHCP renew) then re-advertise in place. Both legs are idempotent and
/// trust-gated — `refreshAnnouncement()` no-ops in quiet mode, `recheck()`
/// no-ops on web — so it is safe to fire on every resume / share-UI open.
/// Kept as ONE function so the app-foreground hook, the share-open
/// trigger, and the empty-state "scan for new peers" button never
/// duplicate the sequence (CLAUDE.md principle #3 + hot-path 3(c)). NOT an
/// always-on loop: callers invoke it on discrete events.
///
/// Takes a [WidgetRef]: every caller is a widget (the app-root lifecycle
/// observer, the home share-open trigger, the empty-state scan button), so
/// the seam reads through the widget's ref.
///
/// `recheck()` lives on [NetworkWatcherImpl], not the
/// [NetworkWatcherRepository] interface — it is an implementation-detail
/// re-sample with a single caller, so this reaches it via a concrete cast
/// rather than widening the domain interface (no premature abstraction).
/// The load-bearing leg (`refreshAnnouncement`) is always interface-typed
/// and always runs.
Future<void> refreshDiscovery(WidgetRef ref) async {
  // recheck() can flip trust -> true; do it (and let the trust stream
  // propagate) before asking discovery to re-broadcast, so a network we
  // just re-trusted actually starts announcing.
  final watcher = ref.read(networkWatcherProvider);
  if (watcher is NetworkWatcherImpl) {
    await watcher.recheck();
  }
  await ref.read(peerDiscoveryProvider).refreshAnnouncement();
}

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
  final s = NotificationService();
  // Audit #41: the service owns a broadcast StreamController for
  // foreground responses. Close it when the container is disposed so a
  // torn-down ProviderContainer (tests / future container swaps) doesn't
  // leak the controller. Mirrors every other disposable provider here.
  ref.onDispose(() => s.dispose());
  return s;
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

/// Phase 5: drives display brightness to maximum while the pairing-code
/// screen shows the QR (so it scans in dim light), restoring on exit. Wraps
/// the screen_brightness plugin behind [BrightnessController] so the pairing
/// screen stays widget-testable with a fake. Best-effort / no-op on hardware
/// without programmatic brightness control.
final brightnessControllerProvider = Provider<BrightnessController>((ref) {
  return ScreenBrightnessController();
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
  // The controller's stream is already seeded with the current state and
  // then emits every transition (audit #52), so return it directly
  // instead of re-seeding it here.
  return ref.watch(pendingSharesControllerProvider).stream;
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
    // Same path the received-file tile "Open" action uses (see
    // _openSavedPath) so the two surfaces never drift.
    openFile: _openSavedPath,
    showMainWindow: tray.showMainWindow,
  );
  ref.onDispose(router.dispose);
  router.start();
  return router;
});

/// Opens a saved file in the OS default handler. Single source of truth for
/// the content:// vs file-path branch, shared by the transfer-done
/// notification ("Open" action) and the received-file tile.
///
/// Slice 5.x.3.5: Android 11+ MediaStore can hand back a `content://` URI
/// when MediaColumns.DATA resolves to null. OpenFilex only handles absolute
/// file paths, so route URIs through the Kotlin channel that fires
/// Intent.ACTION_VIEW with FLAG_GRANT_READ_URI_PERMISSION.
Future<void> _openSavedPath(String path) async {
  if (path.startsWith('content://')) {
    if (Platform.isAndroid) {
      const channel = MethodChannel('sharer.downloads/methods');
      await channel.invokeMethod<bool>('openByUri', {'uri': path});
    }
    return;
  }
  await OpenFilex.open(path);
}

/// Reveals [path] in the OS file manager on desktop (Explorer /select,
/// Finder open -R, Linux xdg-open on the parent dir). On mobile there is no
/// reliable "show in folder" intent, so this degrades to opening the file.
Future<void> _revealSavedPath(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
    return;
  }
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
    return;
  }
  if (Platform.isLinux) {
    final sep = path.lastIndexOf('/');
    final dir = sep > 0 ? path.substring(0, sep) : path;
    await Process.run('xdg-open', [dir]);
    return;
  }
  await _openSavedPath(path);
}

/// Re-shares a received file via the OS share sheet. [origin] positions the
/// iPad share popover. share_plus needs a real file path, so callers gate
/// this off content:// values.
Future<void> _shareSavedPath(String path, {Rect? origin}) async {
  await SharePlus.instance.share(
    ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
  );
}

/// OS-handoff actions for a completed received file, injected into the
/// transfer tile so the widget stays free of open_filex / share_plus /
/// dart:io. Recorder-overridable in tests.
final receivedFileActionsProvider = Provider<ReceivedFileActions>((ref) {
  return const ReceivedFileActions(
    open: _openSavedPath,
    reveal: _revealSavedPath,
    shareOnward: _shareSavedPath,
  );
});
