import 'dart:async';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Slice 5.x.4.3: migrated to cryptography_plus + cryptography_flutter_plus
  // 3.x. The 3.x line auto-registers via Flutter plugin discovery;
  // there is NO longer a CryptographyFlutter.enable() to call. The
  // boot canary below is now the ONLY signal that native AES is
  // actually loaded — if it ever shows `_DartAesGcm` (or any
  // Dart-prefixed runtime type) on Realme/ColorOS, file an issue
  // upstream. See reference_cryptography_flutter.md for the trap
  // that bit us in 5.3.2 and the fallback plan (direct method-channel
  // bridge to javax.crypto).
  final aes = AesGcm.with256bits();
  debugPrint('[sharer.crypto] AES-GCM backend: ${aes.runtimeType}');

  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );

  // Slice 5.x.6: gate the platform-specific bootstrap behind kIsWeb.
  // Every subsystem warmed up below assumes dart:io (Platform.is*,
  // sockets, files) or a platform channel that throws on web. kIsWeb
  // is a compile-time constant — `false` on all native platforms, so
  // the existing Android / Windows / macOS / Linux boot path stays
  // byte-identical.
  //
  // On web we run the UI shell only. mDNS discovery, HTTP server,
  // tray, foreground service, notifications, share-sheet ingestion —
  // all skipped. The Flutter web build is a stepping stone toward
  // slice 6's "receive a file in the browser via WebRTC" feature;
  // for now it just needs to render without crashing.
  if (!kIsWeb) {
    // Slice 5.2.3: must be called before any window_manager API. The
    // tray controller's `setPreventClose(true)` runs during the
    // ProviderContainer warm-up below, so window_manager has to be
    // ready by then. iOS/Android skip the desktop init entirely.
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
    }

    // Slice 5.2.2: must be called before runApp so the FG-service-isolate
    // ↔ main-isolate port is wired before any startService call. No-op
    // on non-Android platforms.
    FlutterForegroundTask.initCommunicationPort();

    // Prewarm mDNS discovery before the first frame. peerDiscoveryProvider
    // has side effects (observe() + broadcast()) that only run when the
    // provider is first read, and the sole other reader is HomeScreen.build
    // — so without this, the slowest, most latency-sensitive part of the
    // share flow doesn't even begin until after the widget tree builds,
    // serialized behind the first frame. Principle #1 (speed is the #1
    // feature) makes cold-start discovery part of the share-path budget;
    // start it concurrently with the rest of boot. start() is trust-gated
    // and idempotent, so HomeScreen's later watch just attaches to the
    // already-running stream.
    container.read(peerDiscoveryProvider);

    // Slice 5.2.2: reading the FG-service controller wires it to the
    // paired-devices stream. If the user already has a pair persisted,
    // the first stream emission will fire startService without UI
    // involvement. Synchronous (no await) and independent of
    // notification init, so it stays on the pre-first-frame path.
    container.read(foregroundServiceControllerProvider);
    // Slice 5.2.3: install the Windows tray icon + flip the
    // close-to-tray prevent flag before the first frame paints.
    // Controller is platform-gated so this is a no-op on non-Windows.
    // Must stay pre-frame: the prevent-close flag has to be set before
    // the window can be closed.
    container.read(windowsTrayControllerProvider);
    // Slice 5.5: subscribes the share-sheet bridge to ACTION_SEND
    // intents and consumes the cold-start share (if the app was
    // launched from the share sheet). Reading the provider runs
    // controller.start(); on non-Android platforms this is a no-op.
    // Synchronous and independent of notification init — kept pre-frame
    // so the cold-start share is captured before the home screen renders.
    container.read(pendingSharesControllerProvider);

    // Phase 4 doc-gap: capture any responder-side pair handshake left in
    // the persisted mailbox by a crash/kill mid-confirm, BEFORE any session
    // activity (and before the PairInviteService expiry sweep, started
    // lazily by the HTTP server / notification coordinator, can touch the
    // mailbox). The detector classifies (interrupted vs expired) + consumes
    // the marker; the home InterruptedPairingBanner surfaces the one-shot
    // "Previous pairing was interrupted — re-pair?" prompt. Fire-and-forget
    // — the FutureProvider memoizes the result for the session.
    container.read(interruptedPairingProvider);

    // Audit #46: do NOT block the first frame on notification init.
    // NotificationService.init() is a platform-plugin round-trip
    // (Android channel registration / Windows WinRT toast registration)
    // and Principle #1 makes cold-start latency part of the share-path
    // budget. Defer the whole init-dependent chain to a post-first-frame
    // callback so the UI paints first; the callback fires ~one frame
    // later, so the "listener attached in the same second the app boots"
    // intent from slice 5.2.1 still holds for any inbound
    // transfer/invite. Ordering inside the callback is load-bearing:
    // init() must COMPLETE before the router is read, because
    // NotificationRouter.start() calls readLaunchDetails() ->
    // getNotificationAppLaunchDetails(), which needs the plugin
    // initialized.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Slice 5.2.1: pre-init notifications + warm up the coordinator so
      // an inbound transfer/invite already has a listener attached.
      await container.read(notificationServiceProvider).init();
      // requestPermission is fire-and-forget — Android 13+ shows the
      // system dialog asynchronously. We don't gate on the answer.
      unawaited(
        container.read(notificationServiceProvider).requestPermission(),
      );
      // Reading the coordinator provider is what starts its listeners.
      container.read(notificationCoordinatorProvider);
      // Slice 5.2.4: subscribes to the foreground notification-response
      // stream + queries `getNotificationAppLaunchDetails()` once for
      // cold-start routing. Must come after the service init above so
      // the plugin is initialized before the launch-details read.
      container.read(notificationRouterProvider);
    });
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SharerApp(),
    ),
  );
}
