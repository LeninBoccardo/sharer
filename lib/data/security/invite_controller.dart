import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../transport/transport_protocol.dart';
import 'pair_invite_client.dart';
import 'pair_invite_service.dart';
import 'tls_key_material_store.dart';

/// Outcome of [InviteController.invite]. Drives the UI between
/// "couldn't reach peer" (snackbar) and "show fingerprint modal".
sealed class InviteOutcome {}

class InviteLaunched extends InviteOutcome {
  InviteLaunched(this.invite);
  final PairInvite invite;
}

class InviteFailed extends InviteOutcome {
  InviteFailed(this.message);
  final String message;
}

/// Wraps [PairInviteService] + [PairInviteClient] + the local identity
/// into a single "tap a peer to start pairing" use-case so the UI never
/// has to coordinate them itself. Also exposes a finalize() that posts
/// the user's verdict to the peer.
class InviteController {
  static const _logName = 'sharer.security.invite.controller';

  InviteController({
    required PairInviteService service,
    required PairInviteClient client,
    required DeviceIdentityRepository identityRepo,
    required TlsKeyMaterialStore tlsStore,
    PeerCacheRepository? peerCache,
  })  : _service = service,
        _client = client,
        _identityRepo = identityRepo,
        _tlsStore = tlsStore,
        _peerCache = peerCache;

  final PairInviteService _service;
  final PairInviteClient _client;
  final DeviceIdentityRepository _identityRepo;
  final TlsKeyMaterialStore _tlsStore;

  /// Slice 5.4: when wired, the initiator caches the responder's
  /// host:port the moment the /pair-invite POST succeeds. The responder
  /// already had us captured by the server-side handler at that point;
  /// this closes the symmetric gap. Optional so test-only code paths
  /// don't have to construct one.
  final PeerCacheRepository? _peerCache;

  /// Initiator entry point. Runs the full create→POST→complete pipeline
  /// and returns once the fingerprint is ready (or we failed).
  Future<InviteOutcome> invite(Peer peer) async {
    if (peer.host == null || peer.port == null) {
      return InviteFailed('Peer is not reachable yet — try again.');
    }
    final tls = await _tlsStore.get();
    final payload = await _service.createInvite(
      responderId: peer.id,
      localCertFingerprintSha256: tls.certificateFingerprintSha256,
    );
    final post = await _client.postInvite(
      host: peer.host!,
      port: peer.port!,
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
    );
    switch (post) {
      case PairInvitePostOk(:final response):
        // Slice 5.4: the host we just used to reach the responder is
        // known to route. Snapshot it under the responder's deviceId so
        // future hot-path uploads + the reciprocal `/pair-finalize`
        // POST can target the same address even if bonsoir starts
        // resolving the responder's mDNS name to something stale.
        if (_peerCache != null) {
          await _peerCache.cacheAddress(
            deviceId: response.responderId,
            host: peer.host!,
            port: peer.port!,
            displayName: response.responderName.isEmpty
                ? peer.name
                : response.responderName,
          );
        }
        final completed = await _service.completeInvite(
          inviteId: payload.inviteId,
          responderId: response.responderId,
          responderName: response.responderName.isEmpty
              ? peer.name
              : response.responderName,
          responderPublicKey: response.responderPublicKey,
          responderEphemeralPublicKey: response.responderEphemeralPublicKey,
          responderCertFingerprintSha256:
              response.responderCertFingerprintSha256,
          observedCertFingerprintSha256:
              response.observedCertFingerprintSha256,
          signature: response.signature,
        );
        switch (completed) {
          case PairInviteReady(:final invite):
            return InviteLaunched(invite);
          case PairInviteCompleteRejected(:final reason):
            _service.abandon(payload.inviteId);
            return InviteFailed('Pairing rejected: $reason');
        }
      case PairInvitePostDeclined(:final statusCode, :final reason):
        _service.abandon(payload.inviteId);
        if (statusCode == 429) {
          return InviteFailed(
            'They already have a pending invite from you, or recently '
            'declined. Try again later.',
          );
        }
        return InviteFailed(
          'Peer declined the invite (HTTP $statusCode${reason.isEmpty ? '' : ': $reason'}).',
        );
      case PairInvitePostNetworkError():
        _service.abandon(payload.inviteId);
        return InviteFailed(
          'Could not reach ${peer.host}:${peer.port}. Make sure both '
          'devices are on the same Wi-Fi.',
        );
      case PairInvitePostMalformed(:final reason):
        _service.abandon(payload.inviteId);
        return InviteFailed('Bad response from peer: $reason');
    }
  }

  /// Local user tapped Match / Doesn't match. Computes the signed
  /// finalize body and posts it to the peer. Local state has already
  /// been updated by [PairInviteService] before the POST goes out, so
  /// even if the peer is unreachable our side knows the verdict.
  ///
  /// [peer] is optional — slice 5.1.2 captures the peer's source IP
  /// at the responder's `/pair-invite` handler, so the responder
  /// path doesn't need a `Peer` from mDNS in hand. When [peer] is
  /// null and there's no captured host either, the POST is skipped
  /// (local state still flips). The slice 5.2.4 router uses this
  /// path for notification-driven decline.
  Future<void> finalize({
    required String inviteId,
    required Peer? peer,
    required bool match,
  }) async {
    final identity = await _identityRepo.get();
    // Audit #35: read peer-derived routing state (cert fingerprint +
    // captured host) BEFORE flipping local match below. markLocalMatched
    // can commit-and-remove the in-flight entry (when the peer already
    // matched), after which peerCertFingerprintFor / peerHostFor return
    // null. Capturing into locals here keeps finalize able to POST even
    // on the commit-in-the-same-call path. See PairInviteService
    // .markLocalMatched ordering contract.
    final peerCertFp = _service.peerCertFingerprintFor(inviteId);
    // Slice 5.1.2: prefer the source-IP captured by the HTTP server
    // when /pair-invite landed (responder side). Falls back to mDNS
    // peer.host on the initiator side, where we don't have a captured
    // IP but already used `peer.host` to send the original invite, so
    // we know it routes.
    final capturedHost = _service.peerHostFor(inviteId);
    final host = capturedHost ?? peer?.host;
    final port = peer?.port ?? TransportProtocol.defaultPort;
    final signed = match
        ? await _service.markLocalMatched(inviteId)
        : await _service.markLocalDeclined(inviteId);
    if (signed == null) {
      _log('finalize no-op: no in-flight $inviteId');
      return;
    }
    if (host == null) {
      _log('finalize skip POST: no host (peer=${peer?.host} '
          'captured=$capturedHost)');
      return;
    }
    if (peerCertFp == null) {
      // Should never happen if the invite was emitted by the service —
      // log + skip rather than crash. The peer's TTL will clean up.
      _log('finalize skip POST: missing peer cert fingerprint for '
          '$inviteId');
      return;
    }
    await _client.postFinalize(
      host: host,
      port: port,
      inviteId: inviteId,
      senderId: identity.id,
      verdict: match ? 'match' : 'decline',
      signatureBase64: signed.signatureBase64,
      peerCertFingerprintSha256: peerCertFp,
    );
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
