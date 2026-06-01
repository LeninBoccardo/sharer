import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/paired_device.dart';
import 'foreground_service_gateway.dart';

/// Slice 5.2.2: lifecycle for the Android foreground service.
///
/// Bound to the paired-devices stream:
///
/// - 0 → ≥1 paired devices: `gateway.startOrUpdate` (shows the idle
///   notification, keeps the process alive in the background).
/// - ≥1 → 0: `gateway.stop` (last pair forgotten — no longer any
///   reason to keep the service up; the OS is free to kill the process
///   when the UI backgrounds).
///
/// Notification text reflects current paired count so the user can
/// glance at the shade and confirm "yes, Sharer is listening for X".
///
/// Platform gating lives entirely inside the gateway — the controller
/// runs the same logic everywhere and the gateway no-ops on
/// non-Android. That makes the controller testable without mocking
/// `dart:io` `Platform`.
class ForegroundServiceController {
  static const _logName = 'sharer.notifications.fg';

  ForegroundServiceController({
    required Stream<List<PairedDevice>> pairedDevices,
    required ForegroundServiceGateway gateway,
  })  : _pairedDevices = pairedDevices,
        _gateway = gateway;

  final Stream<List<PairedDevice>> _pairedDevices;
  final ForegroundServiceGateway _gateway;
  StreamSubscription<List<PairedDevice>>? _sub;
  bool _initialised = false;
  bool _previousNonEmpty = false;

  Future<void> start() async {
    if (_sub != null) return;
    if (!_initialised) {
      await _gateway.init();
      _initialised = true;
    }
    // Seed the edge detector from the platform's ACTUAL service state.
    // This controller reacts only to EDGES of the paired-count stream.
    // If it assumes "not running" but the service was actually already
    // up — an orphaned FG service the OS restarted, or a stale service
    // from a prior session — while the user now has zero pairs, the
    // first empty emission would be a false==false no-op and the
    // orphan would never be stopped, draining battery and showing a
    // misleading idle notification (audit #3). Seeding from isRunning()
    // turns that first empty emission into a true→false edge that
    // correctly stops the service.
    _previousNonEmpty = await _gateway.isRunning();
    _sub = _pairedDevices.listen(_onPairedDevices);
    _log('controller started');
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Idle-notification body. Kept generic on purpose — listing device
  /// names doesn't scale once the user has more than one or two pairs
  /// and adds noise to a notification meant to be invisible. The shade
  /// already has a title that says "Sharer" so the body is just a
  /// status hint.
  static const _idleBody = 'Listening for files';

  Future<void> _onPairedDevices(List<PairedDevice> devices) async {
    final hasPairs = devices.isNotEmpty;
    if (hasPairs == _previousNonEmpty) return;
    _previousNonEmpty = hasPairs;
    if (hasPairs) {
      await _gateway.startOrUpdate(title: 'Sharer', text: _idleBody);
      _log('service started count=${devices.length}');
    } else {
      await _gateway.stop();
      _log('service stopped (no paired devices)');
    }
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
