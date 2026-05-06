import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../security/in_flight_invite_store.dart';
import '../security/pinning_http_client.dart';
import '../security/secure_key_value_store.dart';
import '../transport/transport_protocol.dart';
import 'notification_channels.dart';

const _logName = 'sharer.notifications.bg';

/// Slice 5.2.4.2 — entry point for the background notification isolate.
///
/// Android dispatches notification action presses with
/// `showsUserInterface: false` to a *separate* Dart isolate (the
/// "background" isolate) when the main isolate is dead. That isolate
/// has no Riverpod container, no in-memory state, and a fresh empty
/// global cache. Dependencies have to be reconstructed from scratch.
///
/// Right now we only handle one action this way: **invite Decline**.
/// Everything else either brings the activity forward (View) or has
/// no useful BG semantics (transfer Open also brings the activity
/// forward, since launching a file viewer happens via the OS handler
/// regardless of who's running).
///
/// The handler:
///   1. Parses the inviteId from `pair_invite:<id>` payload.
///   2. Reads the persisted [InFlightInviteEntry] from secure storage.
///      The entry carries everything needed to fire the decline POST,
///      including a pre-signed HMAC so we don't need the per-pair PSK
///      in this isolate.
///   3. POSTs `/pair-finalize` with `verdict=decline` to the peer
///      using the stored cert fingerprint for TLS pinning.
///   4. Deletes the mailbox entry so a duplicate firing (Android
///      sometimes redelivers actions on flaky networks) is a no-op.
///
/// Must be a top-level function with `@pragma('vm:entry-point')` so
/// the AOT compiler keeps the symbol accessible across isolates.

@pragma('vm:entry-point')
Future<void> notificationBackgroundResponseHandler(
  NotificationResponse response,
) async {
  try {
    if (response.actionId != NotificationActions.inviteReject) return;
    final inviteId = _extractInviteId(response.payload);
    if (inviteId == null) {
      _log('BG: action=${response.actionId} but payload not pair_invite — '
          'skipping');
      return;
    }
    _log('BG: handling decline for inviteId=$inviteId');

    final secure = FlutterSecureStorageAdapter();
    final mailbox = InFlightInviteStore(secure);
    final entry = await mailbox.get(inviteId);
    if (entry == null) {
      _log('BG: no mailbox entry for $inviteId — already handled or '
          'expired');
      return;
    }
    final ok = await _postDecline(entry);
    _log('BG: decline POST result for $inviteId: $ok');
    await mailbox.remove(inviteId);
  } catch (e, st) {
    developer.log('BG notification handler crashed',
        error: e, stackTrace: st, name: _logName);
  }
}

String? _extractInviteId(String? payload) {
  if (payload == null) return null;
  if (payload.startsWith('pair_invite:')) {
    return payload.substring('pair_invite:'.length);
  }
  // Windows quirk: actionId mirrors arguments which mirror the
  // payload. The router would normally collapse this, but the BG
  // isolate path runs before the router does — handle it here.
  if (payload.startsWith('${NotificationActions.inviteReject}|')) {
    return payload.substring(NotificationActions.inviteReject.length + 1);
  }
  return null;
}

Future<bool> _postDecline(InFlightInviteEntry entry) async {
  final body = jsonEncode({
    'inviteId': entry.inviteId,
    'senderId': entry.senderId,
    'verdict': 'decline',
    'signature': entry.declineSignatureBase64,
  });
  final uri = Uri.parse('https://${entry.peerHost}:${entry.peerPort}'
      '${TransportProtocol.pairFinalizePath}');
  final http = buildPinningHttpClient(
    expectedFingerprint: entry.peerCertFingerprint,
  );
  try {
    final req = await http
        .postUrl(uri)
        .timeout(const Duration(seconds: 8));
    final encoded = utf8.encode(body);
    req.headers.contentLength = encoded.length;
    req.headers.contentType = ContentType.json;
    req.add(encoded);
    final resp = await req.close().timeout(const Duration(seconds: 8));
    await resp.drain<void>();
    return resp.statusCode == HttpStatus.ok;
  } catch (e, st) {
    developer.log('BG decline POST failed',
        error: e, stackTrace: st, name: _logName);
    return false;
  } finally {
    http.close(force: true);
  }
}

void _log(String message) {
  developer.log(message, name: _logName);
  debugPrint('[$_logName] $message');
}
