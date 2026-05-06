import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_background_handler.dart';
import 'notification_channels.dart';

/// Slice 5.2.4: details captured at app boot if the launch was
/// triggered by a notification tap / action while the app was
/// killed. The router consumes this once the first frame is up and
/// routes to the appropriate destination.
class NotificationLaunch {
  const NotificationLaunch({required this.payload, required this.actionId});
  final String? payload;
  final String? actionId;
}

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

  /// Slice 5.2.4: foreground notification responses (body taps + action
  /// button presses). The router subscribes to drive navigation +
  /// invoke decline flows. Broadcast so multiple listeners can react
  /// — currently only the router, but a future analytics hook would
  /// fit too.
  final _responses = StreamController<NotificationResponse>.broadcast();
  Stream<NotificationResponse> get responses => _responses.stream;

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
      onDidReceiveNotificationResponse: (response) {
        // Foreground responses arrive here. Forward to the broadcast
        // stream so the router can route.
        _log('response action=${response.actionId} '
            'payload=${response.payload}');
        _responses.add(response);
      },
      // Slice 5.2.4.2: Android dispatches notification actions with
      // `showsUserInterface: false` to a separate Dart isolate when
      // the main isolate is dead. The Decline button on a pair-invite
      // notification needs that path — see
      // notification_background_handler.dart for the full flow.
      // Top-level @pragma('vm:entry-point') is required for AOT.
      onDidReceiveBackgroundNotificationResponse:
          notificationBackgroundResponseHandler,
    );

    await _createAndroidChannels();
    _log('init complete');
  }

  /// Slice 5.2.4: returns the launch context if the app was opened
  /// from a notification while killed; otherwise null. Called once at
  /// app boot by the router after [init] completes.
  Future<NotificationLaunch?> readLaunchDetails() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final response = details.notificationResponse;
    if (response == null) return null;
    _log('cold-start launch action=${response.actionId} '
        'payload=${response.payload}');
    return NotificationLaunch(
      payload: response.payload,
      actionId: response.actionId,
    );
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
    // Slice 5.2.4 fix: skip the in-flight toast on Windows. The
    // package's `cancel()` doesn't remove an Action Center toast
    // reliably, so we'd end up with two stacked toasts (in-flight +
    // done) by the end of the transfer. The Windows tray + the
    // transfer-done toast are sufficient — progress is visible
    // in-app via the Transfers section.
    if (Platform.isWindows) return;
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
      notificationDetails: NotificationDetails(
        android: const AndroidNotificationDetails(
          TransferDoneChannel.id,
          TransferDoneChannel.name,
          channelDescription: TransferDoneChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          category: AndroidNotificationCategory.status,
          actions: [
            // showsUserInterface=false: the action invokes our handler
            // which then launches the file via the OS default app —
            // we don't need to bring the Sharer activity forward to
            // do that.
            AndroidNotificationAction(
              NotificationActions.transferOpen,
              'Open',
              showsUserInterface: false,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(),
        // Slice 5.2.4 fix: Windows toast responses report the
        // launch-arguments string in BOTH `actionId` and `payload`,
        // discarding the toast's own payload field. So we encode
        // the file path inline as `transfer_open|<path>` — the
        // router parses the suffix on Windows and falls back to the
        // payload-based path on Android.
        windows: WindowsNotificationDetails(
          actions: [
            WindowsAction(
              content: 'Open',
              arguments: '${NotificationActions.transferOpen}|$savedPath',
              activationType: WindowsActivationType.foreground,
            ),
          ],
        ),
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
      notificationDetails: NotificationDetails(
        android: const AndroidNotificationDetails(
          PairInviteChannel.id,
          PairInviteChannel.name,
          channelDescription: PairInviteChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          actions: [
            AndroidNotificationAction(
              NotificationActions.inviteView,
              'View',
              showsUserInterface: true,
            ),
            // showsUserInterface=false: decline runs entirely in the
            // backgrounded process — no need to surface the modal
            // just to confirm a no.
            AndroidNotificationAction(
              NotificationActions.inviteReject,
              'Decline',
              showsUserInterface: false,
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(),
        // Same Windows-quirk encoding as transfer-open above — the
        // arguments string is what comes back as both actionId and
        // payload, so we inline the invite id.
        windows: WindowsNotificationDetails(
          actions: [
            WindowsAction(
              content: 'View',
              arguments: '${NotificationActions.inviteView}|$inviteId',
              activationType: WindowsActivationType.foreground,
            ),
            // No Decline button on Windows. Toast activation is
            // limited to foreground / protocol; there's no
            // run-in-background-without-restoring-window primitive,
            // so a Decline button would have to bring the window
            // forward — defeating the purpose. The toast's natural
            // dismiss (X on the toast / clear from Action Center)
            // simply lets the invite expire.
          ],
        ),
      ),
      payload: 'pair_invite:$inviteId',
    );
  }

  /// Slice 5.4: a peer dropped this device's pair from their side
  /// (either via /peer-forgot-you or inferred from a 401). Shown as a
  /// one-shot informational toast — same lane as transferDone so the
  /// user knows their device list just changed without them touching it.
  ///
  /// Slice 5.2.4.1: carries a `peer_unpaired:<peerId>` payload so a
  /// body tap reaches the router, which falls through to "open the
  /// main window" per the user's general rule that any notification
  /// body tap should bring the app forward.
  Future<void> showPeerUnpaired({
    required String peerId,
    required String peerName,
    required bool reactive,
  }) async {
    final body = reactive
        ? 'They removed Sharer on their side.'
        : 'They unpaired this device.';
    await _plugin.show(
      id: NotificationIdSpace.peerUnpaired(peerId),
      title: '$peerName unpaired',
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          PeerUnpairedChannel.id,
          PeerUnpairedChannel.name,
          channelDescription: PeerUnpairedChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          category: AndroidNotificationCategory.status,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: 'peer_unpaired:$peerId',
    );
  }

  Future<void> cancelTransferActive(String transferId) =>
      _plugin.cancel(id: NotificationIdSpace.transferActive(transferId));

  Future<void> cancelPairInvite(String inviteId) =>
      _plugin.cancel(id: NotificationIdSpace.pairInvite(inviteId));

  Future<void> dispose() async {
    await _responses.close();
  }

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
    await android.createNotificationChannel(const AndroidNotificationChannel(
      PeerUnpairedChannel.id,
      PeerUnpairedChannel.name,
      description: PeerUnpairedChannel.description,
      importance: Importance.defaultImportance,
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
