import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Slice 5.2.3: Windows tray + close-to-tray.
///
/// On Windows, clicking the window's X button **hides** the window
/// to the tray instead of exiting; only the tray menu's "Quit"
/// actually destroys the window. This is what makes the docs/v1
/// "Background presence" model work on desktop — Sharer keeps its
/// HTTP server bound and mDNS listener running with no visible UI,
/// just an icon in the tray.
///
/// Platform gating: Windows only. macOS / Linux fall through to the
/// default Flutter behaviour (close = exit). iOS / Android no-op.
class WindowsTrayController with TrayListener, WindowListener {
  static const _logName = 'sharer.notifications.tray';

  /// Asset bundled via the `assets/` section of [pubspec.yaml]. The
  /// path is what tray_manager hands to Shell_NotifyIcon at runtime,
  /// which expects an .ico that ships in the runtime data directory.
  static const _trayIconAsset = 'assets/tray_icon.ico';

  static const _menuKeyOpen = 'open';
  static const _menuKeyQuit = 'quit';

  bool _started = false;

  /// Set when the user explicitly chose Quit from the tray menu, so
  /// the next [onWindowClose] event lets the close happen instead of
  /// hiding to tray.
  bool _quitting = false;

  Future<void> start() async {
    if (!Platform.isWindows) return;
    if (_started) return;
    _started = true;

    // setPreventClose flips Flutter's default handling — instead of
    // tearing the window down on the X click, the framework just
    // fires onWindowClose and lets us decide.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    await trayManager.setIcon(_trayIconAsset);
    await trayManager.setToolTip('Sharer');
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(key: _menuKeyOpen, label: 'Open Sharer'),
        MenuItem.separator(),
        MenuItem(key: _menuKeyQuit, label: 'Quit'),
      ]),
    );
    trayManager.addListener(this);
    _log('tray + close-to-tray active');
  }

  Future<void> dispose() async {
    if (!_started) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    _started = false;
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    // Single left-click = restore the window. Matches every chat /
    // messenger app's tray convention on Windows.
    unawaited(_restoreWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuKeyOpen:
        unawaited(_restoreWindow());
      case _menuKeyQuit:
        unawaited(_quit());
    }
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(windowManager.hide());
    _log('hide-to-tray');
  }

  Future<void> _restoreWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Slice 5.2.4: exposed for the [NotificationRouter] so it can
  /// bring the window forward when a notification action that needs
  /// UI fires while the window is hidden to tray.
  Future<void> showMainWindow() async {
    if (!Platform.isWindows) return;
    await _restoreWindow();
  }

  Future<void> _quit() async {
    _quitting = true;
    // Re-enable the default close behaviour so destroy() actually
    // tears the window down + the process exits.
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
