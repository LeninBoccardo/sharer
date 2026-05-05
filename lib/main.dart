import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

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

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SharerApp(),
    ),
  );
}
