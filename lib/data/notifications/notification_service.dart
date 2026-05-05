import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_channels.dart';

/// Stable Windows AppUserModelId. Re-used in any future Windows-side
/// branding (tray app id, single-instance lock). Format follows the
/// Microsoft guidance `<CompanyName>.<ProductName>.<SubProduct>`.
const String _windowsAppUserModelId = 'Sharer.Sharer.App';

/// Stable Windows toast GUID. Generated once for this app; do NOT
/// regenerate — Windows treats a new GUID as a new app and would orphan
/// any pinned tile / start-menu shortcut metadata.
const String _windowsToastGuid = '4f0f5b2c-1c1c-4c5e-9b1a-7e0c8c5e2d4a';

/// Slice 5.2.1: thin platform wrapper around `flutter_local_notifications`.
///
/// Designed to be safe to call from anywhere — every method is a no-op
/// on platforms without notification support (we only target Android +
/// Windows for v1 per OQ-10; iOS / macOS / Linux are best-effort and do
/// not crash the app). Production wiring is a single instance owned by
/// [notificationServiceProvider]; tests can override the provider to
/// inject a fake plugin.
class NotificationService {
  static const _logName = 'sharer.notifications';

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  /// Initialise channels + the platform plugin. Idempotent — safe to
  /// call from `main()` and again from a unit test setUp.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings(
      // Default launcher icon. Slice 5.2.2 will swap to a transparent
      // monochrome notification icon (Android requires monochrome on
      // API 21+ — coloured launcher icons render as a white square).
      '@mipmap/ic_launcher',
    );
    const darwinInit = DarwinInitializationSettings(
      // iOS / macOS are out of scope per OQ-9; the init must succeed
      // (i.e. not crash the app) but no permission is requested here.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linuxInit = LinuxInitializationSettings(defaultActionName: 'Open');
    const windowsInit = WindowsInitializationSettings(
      appName: 'Sharer',
      appUserModelId: _windowsAppUserModelId,
      guid: _windowsToastGuid,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
        linux: linuxInit,
        windows: windowsInit,
      ),
    );

    await _createAndroidChannels();
    _log('init complete');
  }

  /// Android 13+ POST_NOTIFICATIONS runtime permission. Returns the
  /// granted state; on platforms that don't gate notifications behind a
  /// runtime permission this returns `true`.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission();
    _log('runtime permission granted=$granted');
    return granted ?? false;
  }

  Future<void> showTransferActive({
    required String transferId,
    required String peerName,
    required String fileName,
    required int bytesTransferred,
    required int totalBytes,
  }) async {
    final progress =
        totalBytes > 0 ? (bytesTransferred * 100 ~/ totalBytes) : 0;
    final indeterminate = totalBytes <= 0;
    final body = totalBytes > 0
        ? '${_formatBytes(bytesTransferred)} of ${_formatBytes(totalBytes)}'
        : _formatBytes(bytesTransferred);
    await _plugin.show(
      id: NotificationIdSpace.transferActive(transferId),
      title: 'Receiving $fileName',
      body: 'From $peerName • $body',
      // No `WindowsNotificationDetails.subtitle` — flutter_local_notifications
      // on Windows renders the subtitle as a second body line, so
      // setting it duplicates whatever the body already conveys
      // (caught during slice 5.2.3 real-device validation).
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          TransferActiveChannel.id,
          TransferActiveChannel.name,
          channelDescription: TransferActiveChannel.description,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          onlyAlertOnce: true,
          showProgress: true,
          progress: progress,
          maxProgress: 100,
          indeterminate: indeterminate,
          category: AndroidNotificationCategory.progress,
          // Tap routes to the app; action buttons are slice 5.2.4.
        ),
        iOS: const DarwinNotificationDetails(presentSound: false),
      ),
    );
  }

  Future<void> showTransferDone({
    required String transferId,
    required String fileName,
    required String savedPath,
  }) async {
    // Cancel the active-progress notification before posting the
    // completion toast so the shade flips cleanly from "in flight" to
    // "done" instead of stacking two entries.
    await cancelTransferActive(transferId);
    await _plugin.show(
      id: NotificationIdSpace.transferDone(transferId),
      title: 'Saved $fileName',
      body: 'Tap to open • Saved to Downloads',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          TransferDoneChannel.id,
          TransferDoneChannel.name,
          channelDescription: TransferDoneChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          category: AndroidNotificationCategory.status,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: 'transfer_done:$transferId|$savedPath',
    );
  }

  Future<void> showTransferFailed({
    required String transferId,
    required String fileName,
    required String error,
  }) async {
    await cancelTransferActive(transferId);
    await _plugin.show(
      id: NotificationIdSpace.transferDone(transferId),
      title: 'Failed to receive $fileName',
      body: error,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          TransferDoneChannel.id,
          TransferDoneChannel.name,
          channelDescription: TransferDoneChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          category: AndroidNotificationCategory.error,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showPairInvite({
    required String inviteId,
    required String peerName,
    required String fingerprint,
  }) async {
    final spaced = _spaceFingerprint(fingerprint);
    await _plugin.show(
      id: NotificationIdSpace.pairInvite(inviteId),
      title: 'Pair with $peerName?',
      body: 'Verify code: $spaced',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          PairInviteChannel.id,
          PairInviteChannel.name,
          channelDescription: PairInviteChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: 'pair_invite:$inviteId',
    );
  }

  Future<void> cancelTransferActive(String transferId) =>
      _plugin.cancel(id: NotificationIdSpace.transferActive(transferId));

  Future<void> cancelPairInvite(String inviteId) =>
      _plugin.cancel(id: NotificationIdSpace.pairInvite(inviteId));

  Future<void> _createAndroidChannels() async {
    if (!Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    // Eagerly create all four channels at startup so first-emission is
    // instant. Re-creating an existing channel is a no-op on the
    // platform side.
    await android.createNotificationChannel(const AndroidNotificationChannel(
      IdleChannel.id,
      IdleChannel.name,
      description: IdleChannel.description,
      importance: Importance.min,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      TransferActiveChannel.id,
      TransferActiveChannel.name,
      description: TransferActiveChannel.description,
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      TransferDoneChannel.id,
      TransferDoneChannel.name,
      description: TransferDoneChannel.description,
      importance: Importance.defaultImportance,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      PairInviteChannel.id,
      PairInviteChannel.name,
      description: PairInviteChannel.description,
      importance: Importance.high,
    ));
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }

  /// "123456" → "12 34 56" — matches the spacing used in
  /// [PairInviteModal] so the user can compare digits at a glance.
  static String _spaceFingerprint(String fp) {
    if (fp.length != 6) return fp;
    return '${fp.substring(0, 2)} ${fp.substring(2, 4)} ${fp.substring(4)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
