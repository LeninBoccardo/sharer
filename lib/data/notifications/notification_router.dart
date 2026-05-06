import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../presentation/pairing/invite_controller.dart';
import 'notification_channels.dart';
import 'notification_service.dart';

/// Slice 5.2.4: opens a saved file in the OS default handler.
/// Abstracted so tests can record calls instead of touching the
/// platform plugin.
typedef OpenFileFn = Future<void> Function(String path);

/// Slice 5.2.4: brings the Sharer window to the foreground on the
/// platforms where it can be hidden (Windows tray, iOS background).
/// Android's `showsUserInterface=true` on the action handles this
/// natively, so the no-op fallback is fine on mobile.
typedef ShowMainWindowFn = Future<void> Function();

/// Slice 5.2.4: dispatches notification responses (foreground +
/// cold-start launches) to the right destination.
///
/// Three response shapes:
///
/// - `transfer_open` action / body tap on a "Saved X" notification →
///   open the file in the OS default handler.
/// - `invite_view` action / body tap on a "Pair with X?" notification
///   → bring the window forward; the home screen's invite-stream
///   listener already opens the fingerprint modal when the matching
///   `awaitingFingerprint` event is in-flight.
/// - `invite_reject` action → invoke the decline flow without
///   surfacing any UI. Android only — Windows toasts have no
///   background activation primitive.
///
/// Cold-start: [start] reads `getNotificationAppLaunchDetails()`
/// once and routes whatever the user tapped before the app process
/// existed.
class NotificationRouter {
  static const _logName = 'sharer.notifications.router';

  NotificationRouter({
    required NotificationService service,
    required InviteController inviteController,
    required OpenFileFn openFile,
    required ShowMainWindowFn showMainWindow,
  })  : _service = service,
        _inviteController = inviteController,
        _openFile = openFile,
        _showMainWindow = showMainWindow;

  final NotificationService _service;
  final InviteController _inviteController;
  final OpenFileFn _openFile;
  final ShowMainWindowFn _showMainWindow;
  StreamSubscription<NotificationResponse>? _sub;

  Future<void> start() async {
    _sub = _service.responses.listen(_handleResponse);
    final launch = await _service.readLaunchDetails();
    if (launch != null) {
      await _route(actionId: launch.actionId, payload: launch.payload);
      _log('handled cold-start launch');
    }
    _log('start');
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _handleResponse(NotificationResponse response) {
    unawaited(_route(
      actionId: response.actionId,
      payload: response.payload,
    ));
  }

  Future<void> _route({String? actionId, String? payload}) async {
    // Windows quirk: a notification response carries the launch-args
    // string in BOTH `actionId` and `payload`, with no way to
    // distinguish "user tapped the body" from "user tapped a button"
    // beyond inspecting the namespace of that string. So we
    // recognise body-tap launch strings (which start with our
    // payload prefixes) and treat them as taps with actionId=null.
    final normalizedAction = _normaliseAction(actionId, payload);

    // ---- Transfer-done: open the saved file ----
    final transferPath = _decodeTransferOpen(normalizedAction, payload);
    if (transferPath != null) {
      if (transferPath.isEmpty) {
        _log('transfer route: empty saved path');
        return;
      }
      await _openFile(transferPath);
      _log('opened file: $transferPath');
      return;
    }

    // ---- Invite decline (Android-only button) ----
    final declineInviteId = _decodeInviteAction(
      normalizedAction,
      payload,
      NotificationActions.inviteReject,
    );
    if (declineInviteId != null) {
      await _inviteController.finalize(
        inviteId: declineInviteId,
        peer: null,
        match: false,
      );
      _log('declined invite: $declineInviteId');
      return;
    }

    // ---- Invite view: bring the window forward ----
    final viewInviteId = _decodeInviteAction(
      normalizedAction,
      payload,
      NotificationActions.inviteView,
    );
    if (viewInviteId != null) {
      // The home screen's pair-invite stream listener opens the
      // fingerprint modal whenever an awaitingFingerprint event is
      // on the wire — we just need the window to be visible. Slice
      // 5.2.4 also adds an "open the in-flight invite on home-screen
      // mount" path so a cold-start / window-restore doesn't miss
      // the already-emitted event.
      await _showMainWindow();
      _log('showed main window for invite view');
      return;
    }

    // Slice 5.2.4.1: default body-tap behavior — bring the app
    // forward whenever the user taps the body of a notification we
    // don't have a specific route for. Covers `peer_unpaired:<id>`
    // and any future notifications that don't carry a specific
    // payload. We only do this for body taps (normalizedAction ==
    // null); unknown action buttons stay no-ops so a stray button
    // press can't open the app.
    if (normalizedAction == null) {
      await _showMainWindow();
      _log('default body tap → main window (action=$actionId payload=$payload)');
      return;
    }

    _log('no route for action=$actionId payload=$payload');
  }

  /// Returns either an action constant (`transfer_open`,
  /// `invite_view`, `invite_reject`) — possibly with a `|<extra>`
  /// suffix for the Windows-encoded path/inviteId — or null when
  /// this looks like a body tap (Windows reports the payload as
  /// actionId; we collapse that back to null so payload-based
  /// extraction handles it).
  static String? _normaliseAction(String? actionId, String? payload) {
    if (actionId == null) return null;
    // Body-tap markers live in a different namespace from action
    // ids; collapse them to null so the payload branches handle
    // them uniformly. Slice 5.2.4.1 adds `peer_unpaired:` to the
    // list — Windows mirrors the payload into actionId for body
    // taps, and the new peer-unpaired toast carries that payload.
    if (actionId.startsWith('transfer_done:') ||
        actionId.startsWith('pair_invite:') ||
        actionId.startsWith('peer_unpaired:')) {
      return null;
    }
    return actionId;
  }

  /// Resolves the saved file path for a transfer-open response.
  /// Returns null when this isn't a transfer-open at all.
  static String? _decodeTransferOpen(String? action, String? payload) {
    if (action != null) {
      if (action == NotificationActions.transferOpen) {
        // Android: path lives in the payload.
        return _extractTransferPathFromPayload(payload);
      }
      if (action.startsWith('${NotificationActions.transferOpen}|')) {
        // Windows: path inlined into the action's arguments.
        return action.substring(NotificationActions.transferOpen.length + 1);
      }
      return null;
    }
    // Body tap with payload prefix.
    return _extractTransferPathFromPayload(payload);
  }

  /// Returns the invite id when [action] (or, for body taps, the
  /// payload) targets the given invite action constant; else null.
  static String? _decodeInviteAction(
    String? action,
    String? payload,
    String actionConstant,
  ) {
    if (action != null) {
      if (action == actionConstant) {
        // Android: invite id in the payload.
        return _extractInviteIdFromPayload(payload);
      }
      if (action.startsWith('$actionConstant|')) {
        // Windows: invite id inlined into the action's arguments.
        return action.substring(actionConstant.length + 1);
      }
      return null;
    }
    // Body tap is only recognised as the View action — the only
    // body-tap-meaningful invite path. Decline is button-only.
    if (actionConstant == NotificationActions.inviteView) {
      return _extractInviteIdFromPayload(payload);
    }
    return null;
  }

  /// `transfer_done:<id>|<savedPath>` → savedPath. The path may
  /// contain colons (`C:\...`), so the split takes the first `:`
  /// (the prefix) and the first `|` (the id/path boundary).
  static String? _extractTransferPathFromPayload(String? payload) {
    if (payload == null || !payload.startsWith('transfer_done:')) return null;
    final afterPrefix = payload.substring('transfer_done:'.length);
    final pipe = afterPrefix.indexOf('|');
    if (pipe < 0) return null;
    return afterPrefix.substring(pipe + 1);
  }

  /// `pair_invite:<id>` → id.
  static String? _extractInviteIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith('pair_invite:')) return null;
    return payload.substring('pair_invite:'.length);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
