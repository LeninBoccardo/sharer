import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

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

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SharerApp(),
    ),
  );
}
