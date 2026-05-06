import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

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

  // Slice 5.2.1: pre-init notifications + warm up the coordinator
  // before the first frame so an inbound transfer/invite that lands in
  // the same second the app boots already has a listener attached.
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  await container.read(notificationServiceProvider).init();
  // requestPermission is fire-and-forget — Android 13+ shows the
  // system dialog asynchronously. We don't gate boot on the answer.
  unawaited(container.read(notificationServiceProvider).requestPermission());
  // Reading the coordinator provider is what starts its listeners.
  container.read(notificationCoordinatorProvider);
  // Slice 5.2.2: same pattern — reading the FG-service controller
  // wires it to the paired-devices stream. If the user already has a
  // pair persisted, the first stream emission will fire startService
  // without UI involvement.
  container.read(foregroundServiceControllerProvider);
  // Slice 5.2.3: install the Windows tray icon + flip the
  // close-to-tray prevent flag before the first frame paints.
  // Controller is platform-gated so this is a no-op on non-Windows.
  container.read(windowsTrayControllerProvider);
  // Slice 5.2.4: subscribes to the foreground notification-response
  // stream + queries `getNotificationAppLaunchDetails()` once for
  // cold-start routing. Must come after the service init above so
  // the stream is wired before the launch-details read.
  container.read(notificationRouterProvider);
  // Slice 5.5: subscribes the share-sheet bridge to ACTION_SEND
  // intents and consumes the cold-start share (if the app was
  // launched from the share sheet). Reading the provider runs
  // controller.start(); on non-Android platforms this is a no-op.
  container.read(pendingSharesControllerProvider);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SharerApp(),
    ),
  );
}
