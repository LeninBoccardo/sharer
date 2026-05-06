import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/paired_device.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../transport/transport_protocol.dart';
import 'pair_invite_client.dart';
import 'peer_forget_signer.dart';

/// Reasons a [ForgetEvent] fires. The notification coordinator listens
/// for these and shows a toast on the *forgotten* side so the user
/// knows their pair was unilaterally dropped.
enum ForgetCause {
  /// We received an HMAC-verified `/peer-forgot-you` POST from the peer.
  proactive,

  /// Our outbound `/upload` (or other signed request) got 401 from a
  /// device that was paired in our store. The peer almost certainly
  /// removed us.
  reactive,
}

class ForgetEvent {
  ForgetEvent({
    required this.peerId,
    required this.peerName,
    required this.cause,
  });

  final String peerId;
  final String peerName;
  final ForgetCause cause;
}

/// Slice 5.4: coordinates the proactive + reactive forget paths.
///
/// **Proactive (we forget them):** [forgetPeer] looks up the peer's
/// last-known address from the peer cache, fires a best-effort signed
/// `/peer-forgot-you` POST, and then removes the local PairedDevice +
/// peer-cache entry. The POST is fire-and-forget — if it fails (peer
/// offline, network gone) the local removal still happens. The peer's
/// reactive 401 path will catch up on their next outbound send.
///
/// **Proactive incoming (they forgot us):** [recordRemoteForgot] is
/// called by the HTTP server after `/peer-forgot-you` HMAC verifies.
/// Removes the local PairedDevice and emits a [ForgetEvent] so the UI
/// can surface a "X has unpaired this device" toast.
///
/// **Reactive (we infer they forgot us):** [recordReactive401] is called
/// by the transport layer when an outbound signed request to a paired
/// peer gets 401. Same removal + event.
///
/// All three paths converge on `pairedRepo.remove() + peerCache.remove()
/// + maybe-emit`. Idempotent — calling twice is harmless.
class ForgetService {
  static const _logName = 'sharer.security.forget';

  ForgetService({
    required PairedDevicesRepository pairedRepo,
    required PeerCacheRepository peerCache,
    required PairInviteClient client,
    required DeviceIdentityRepository identityRepo,
  })  : _pairedRepo = pairedRepo,
        _peerCache = peerCache,
        _client = client,
        _identityRepo = identityRepo;

  final PairedDevicesRepository _pairedRepo;
  final PeerCacheRepository _peerCache;
  final PairInviteClient _client;
  final DeviceIdentityRepository _identityRepo;

  final _events = StreamController<ForgetEvent>.broadcast();
  Stream<ForgetEvent> get events => _events.stream;

  /// User-initiated forget. Best-effort notification + always-removes
  /// locally, regardless of whether the peer was reachable.
  Future<void> forgetPeer(PairedDevice peer) async {
    final cached = await _peerCache.getById(peer.deviceId);
    final host = cached?.host;
    final port = cached?.port;
    final fingerprint = peer.certFingerprint;

    // Notify the peer in the background. We never await — the local
    // removal happens regardless, so a slow / unreachable peer doesn't
    // freeze the UI.
    if (host != null && fingerprint != null && fingerprint.isNotEmpty) {
      final identity = await _identityRepo.get();
      final sig = signPeerForgotYou(psk: peer.psk, senderId: identity.id);
      unawaited(
        _client.postPeerForgotYou(
          host: host,
          port: port ?? TransportProtocol.defaultPort,
          senderId: identity.id,
          signatureBase64: sig,
          peerCertFingerprintSha256: fingerprint,
        ),
      );
      _log('forgetPeer ${peer.deviceId}: notify $host:$port');
    } else {
      _log('forgetPeer ${peer.deviceId}: no cached host or cert fingerprint, '
          'skipping POST (peer will discover on next send)');
    }

    await _pairedRepo.remove(peer.deviceId);
    await _peerCache.remove(peer.deviceId);
    _log('forgetPeer ${peer.deviceId}: local removal done');
  }

  /// Server-side: an HMAC-verified `/peer-forgot-you` arrived. Remove
  /// the peer and emit a notification event.
  Future<void> recordRemoteForgot(PairedDevice peer) async {
    await _pairedRepo.remove(peer.deviceId);
    await _peerCache.remove(peer.deviceId);
    _events.add(ForgetEvent(
      peerId: peer.deviceId,
      peerName: peer.displayName,
      cause: ForgetCause.proactive,
    ));
    _log('recordRemoteForgot ${peer.deviceId} (${peer.displayName})');
  }

  /// Transport-side: a 401 came back from a peer we thought was paired.
  /// Treat it as silent removal.
  Future<void> recordReactive401(PairedDevice peer) async {
    await _pairedRepo.remove(peer.deviceId);
    await _peerCache.remove(peer.deviceId);
    _events.add(ForgetEvent(
      peerId: peer.deviceId,
      peerName: peer.displayName,
      cause: ForgetCause.reactive,
    ));
    _log('recordReactive401 ${peer.deviceId} (${peer.displayName})');
  }

  Future<void> dispose() async {
    await _events.close();
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
