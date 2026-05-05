import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'foreground_service_handler.dart';
import 'notification_channels.dart';

/// Thin abstraction over `flutter_foreground_task`'s static API so the
/// [ForegroundServiceController] can be driven by a fake in tests
/// without touching the real platform plugin. Production binding is
/// [FlutterForegroundServiceGateway].
abstract class ForegroundServiceGateway {
  /// Configure the package once (notification channel, task options,
  /// etc.). Idempotent. No-op on non-Android.
  Future<void> init();

  /// Returns whether the service is currently running on the platform.
  Future<bool> isRunning();

  /// Start (or update, if already running) the foreground service. The
  /// notification stays on the [IdleChannel] so it shows up at the
  /// bottom of the shade with no peek + no sound. No-op on non-Android.
  Future<void> startOrUpdate({
    required String title,
    required String text,
  });

  Future<void> stop();

  /// Slice 5.2.2: Android-only — true when the user has whitelisted
  /// the app from battery optimization. Aggressive OEMs (Xiaomi,
  /// Oppo, OnePlus, Huawei, Realme) kill backgrounded apps even with
  /// a foreground service running unless they're whitelisted; this is
  /// what surfaces the "open settings" prompt on the home screen.
  /// Returns true on platforms where the concept doesn't apply.
  Future<bool> isIgnoringBatteryOptimizations();

  /// Deep-links to the system settings screen so the user can flip
  /// the whitelist toggle. Returns true on success. No-op on
  /// non-Android.
  Future<bool> requestIgnoreBatteryOptimizations();
}

class FlutterForegroundServiceGateway implements ForegroundServiceGateway {
  /// Arbitrary stable id — Android uses it internally for the FG
  /// notification. Bumping this ID would invalidate any pinned
  /// shortcut metadata; keep it stable across releases.
  static const _serviceId = 1001;

  bool _initialised = false;

  @override
  Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_initialised) return;
    _initialised = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: IdleChannel.id,
        channelName: IdleChannel.name,
        channelDescription: IdleChannel.description,
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        // VISIBILITY_SECRET hides the FG notification from the lock
        // screen entirely — when paired-and-idle, no surface at all
        // until the user pulls the shade open.
        visibility: NotificationVisibility.VISIBILITY_SECRET,
        onlyAlertOnce: true,
        showWhen: false,
        showBadge: false,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        // iOS deferred (OQ-9). Init must succeed but we don't surface
        // any iOS-side notification.
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic event — the FG service exists to keep the main
        // isolate's process alive, not to do its own work.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return FlutterForegroundTask.isRunningService;
  }

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid) return;
    if (await isRunning()) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      // Android 14+ requires the type at startForeground time. The
      // declared `<service>` in AndroidManifest.xml must include this
      // value too.
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: text,
      callback: sharerForegroundTaskCallback,
    );
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!await isRunning()) return;
    await FlutterForegroundTask.stopService();
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    return FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}
