import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../data/security/pair_invite_client.dart';
import '../../data/security/pair_invite_service.dart';
import '../../data/security/tls_key_material_store.dart';
import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';
import '../../domain/repositories/device_identity_repository.dart';

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
  })  : _service = service,
        _client = client,
        _identityRepo = identityRepo,
        _tlsStore = tlsStore;

  final PairInviteService _service;
  final PairInviteClient _client;
  final DeviceIdentityRepository _identityRepo;
  final TlsKeyMaterialStore _tlsStore;

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
  Future<void> finalize({
    required PairInvite invite,
    required Peer? peer,
    required bool match,
  }) async {
    final identity = await _identityRepo.get();
    final peerCertFp =
        _service.peerCertFingerprintFor(invite.inviteId);
    final signed = match
        ? await _service.markLocalMatched(invite.inviteId)
        : await _service.markLocalDeclined(invite.inviteId);
    if (signed == null) {
      _log('finalize no-op: no in-flight ${invite.inviteId}');
      return;
    }
    if (peer?.host == null || peer?.port == null) {
      _log('finalize skip POST: peer not reachable');
      return;
    }
    if (peerCertFp == null) {
      // Should never happen if the invite was emitted by the service —
      // log + skip rather than crash. The peer's TTL will clean up.
      _log('finalize skip POST: missing peer cert fingerprint for '
          '${invite.inviteId}');
      return;
    }
    await _client.postFinalize(
      host: peer!.host!,
      port: peer.port!,
      inviteId: invite.inviteId,
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
