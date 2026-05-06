import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/transfer.dart';
import '../security/forget_service.dart';
import 'notification_service.dart';

/// Slice 5.2.1: aggregates the transfer + pair-invite streams into
/// notification calls. Lives for the lifetime of the app — instantiated
/// once at boot from the composition root, disposed on shutdown.
///
/// Stateful by design: the [TransferService] stream emits a fresh
/// snapshot on every change, so the coordinator diffs against the
/// previous snapshot to figure out whether each transfer is "newly
/// started", "still in flight" (progress update), or "just finished".
/// Same for invites — the service re-emits the invite on every status
/// transition, but we only want to surface the awaitingFingerprint
/// notification once per id and cancel it on a terminal status.
class NotificationCoordinator {
  static const _logName = 'sharer.notifications.coord';

  /// Throttle progress notification updates to ~256 KB jumps so we
  /// don't spam the platform plugin during a fast transfer. Same number
  /// the [TransferServiceImpl] uses internally for stream coalescing —
  /// keeping them aligned avoids "stale" progress in the shade.
  static const int _progressBytesThreshold = 256 * 1024;

  NotificationCoordinator({
    required NotificationService service,
    required Stream<List<Transfer>> transfers,
    required Stream<PairInvite> invites,
    required Stream<bool> isTrusted,
    Stream<ForgetEvent>? forgetEvents,
  })  : _service = service,
        _transfersStream = transfers,
        _invitesStream = invites,
        _trustedStream = isTrusted,
        _forgetStream = forgetEvents;

  final NotificationService _service;
  final Stream<List<Transfer>> _transfersStream;
  final Stream<PairInvite> _invitesStream;
  final Stream<bool> _trustedStream;
  final Stream<ForgetEvent>? _forgetStream;

  StreamSubscription<List<Transfer>>? _transfersSub;
  StreamSubscription<PairInvite>? _invitesSub;
  StreamSubscription<bool>? _trustedSub;
  StreamSubscription<ForgetEvent>? _forgetSub;

  /// Last-seen transfer state per id, so we can diff to detect
  /// transitions (started → completed, etc.). Pruned when a transfer
  /// reaches a terminal status and we cancel its notification.
  final Map<String, _TransferSnapshot> _seen = {};

  /// Invite ids we've already shown a notification for. Cleared when
  /// the invite hits a terminal status (completed / declined / expired)
  /// so a re-pair attempt with the same peer surfaces a fresh
  /// notification.
  final Set<String> _shownInvites = {};

  /// Slice 4.6 spec: `/pair-invite` is registered only on trusted
  /// networks. While untrusted, no invite can land — we use this flag
  /// to defensively discard any in-flight invite emission and to also
  /// suppress notifications if a stale event slipped through.
  bool _trusted = true;

  void start() {
    _transfersSub = _transfersStream.listen(_onTransfers);
    _invitesSub = _invitesStream.listen(_onInvite);
    _trustedSub = _trustedStream.listen((value) => _trusted = value);
    _forgetSub = _forgetStream?.listen(_onForget);
    _log('start');
  }

  Future<void> dispose() async {
    await _transfersSub?.cancel();
    await _invitesSub?.cancel();
    await _trustedSub?.cancel();
    await _forgetSub?.cancel();
    _transfersSub = null;
    _invitesSub = null;
    _trustedSub = null;
    _forgetSub = null;
    _log('dispose');
  }

  /// Slice 5.4: a peer dropped this device's pair (proactively via
  /// /peer-forgot-you, or inferred from a 401 reactive event). Either
  /// way the local PairedDevice is already gone — surface a toast so
  /// the user notices their device list shrank.
  void _onForget(ForgetEvent event) {
    unawaited(_service.showPeerUnpaired(
      peerId: event.peerId,
      peerName: event.peerName,
      reactive: event.cause == ForgetCause.reactive,
    ));
  }

  void _onTransfers(List<Transfer> snapshot) {
    final aliveIds = <String>{};
    for (final t in snapshot) {
      // Outgoing sends already give the user feedback in the UI; the
      // notification surface is for *incoming* transfers, where the
      // app may not even be foregrounded.
      if (t.direction != TransferDirection.receiving) continue;
      aliveIds.add(t.id);
      final prev = _seen[t.id];
      _handleTransferTransition(prev, t);
      _seen[t.id] = _TransferSnapshot.from(t);
    }
    // Drop entries that fell off the service's bounded list (it evicts
    // old terminals after 50). No notification action needed — the
    // service-side eviction already happened, and these were terminal.
    _seen.removeWhere((id, _) => !aliveIds.contains(id));
  }

  void _handleTransferTransition(_TransferSnapshot? prev, Transfer current) {
    switch (current.status) {
      case TransferStatus.pending:
      case TransferStatus.inProgress:
        if (prev == null || prev.status != TransferStatus.inProgress) {
          // Transition into in-flight from any non-in-flight state →
          // post the active notification. Includes the pending → inProgress
          // edge as well as direct entry at inProgress.
          unawaited(_service.showTransferActive(
            transferId: current.id,
            peerName: current.peerName,
            fileName: current.fileName,
            bytesTransferred: current.bytesTransferred,
            totalBytes: current.totalBytes,
          ));
          return;
        }
        // Still in flight; only re-emit if the bytes jumped enough to
        // be worth updating the platform notification.
        final delta = current.bytesTransferred - prev.bytesTransferred;
        final isFinalByte = current.totalBytes > 0 &&
            current.bytesTransferred >= current.totalBytes;
        if (delta < _progressBytesThreshold && !isFinalByte) return;
        unawaited(_service.showTransferActive(
          transferId: current.id,
          peerName: current.peerName,
          fileName: current.fileName,
          bytesTransferred: current.bytesTransferred,
          totalBytes: current.totalBytes,
        ));
      case TransferStatus.completed:
        if (prev?.status == TransferStatus.completed) return;
        unawaited(_service.showTransferDone(
          transferId: current.id,
          fileName: current.fileName,
          savedPath: current.savedPath ?? '',
        ));
      case TransferStatus.failed:
        if (prev?.status == TransferStatus.failed) return;
        unawaited(_service.showTransferFailed(
          transferId: current.id,
          fileName: current.fileName,
          error: current.errorMessage ?? 'Transfer failed',
        ));
      case TransferStatus.cancelled:
        if (prev?.status == TransferStatus.cancelled) return;
        unawaited(_service.cancelTransferActive(current.id));
    }
  }

  void _onInvite(PairInvite invite) {
    // Defensive — pair routes are trust-gated at the server (slice 4.6
    // + 5.1), so an invite emission while untrusted would itself be a
    // bug. Don't notify if we somehow see one.
    if (!_trusted) {
      _log('drop invite ${invite.inviteId} (network not trusted)');
      return;
    }

    // Initiator-side invites are surfaced by the home screen / pair
    // flow itself — the user is already actively driving the modal, no
    // notification needed. Only inbound (responder) invites are a
    // background-delivery concern.
    if (invite.role != PairInviteRole.responder) return;

    switch (invite.status) {
      case PairInviteStatus.awaitingFingerprint:
      case PairInviteStatus.localMatched:
        if (!_shownInvites.add(invite.inviteId)) return;
        unawaited(_service.showPairInvite(
          inviteId: invite.inviteId,
          peerName: invite.peerName,
          fingerprint: invite.fingerprint,
        ));
      case PairInviteStatus.completed:
      case PairInviteStatus.declined:
      case PairInviteStatus.expired:
        if (!_shownInvites.remove(invite.inviteId)) return;
        unawaited(_service.cancelPairInvite(invite.inviteId));
    }
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}

/// Minimal projection of a [Transfer] kept across snapshots. We need
/// just enough to detect transitions; copying the whole object would
/// keep the FilePayload byte stream alive longer than necessary.
class _TransferSnapshot {
  _TransferSnapshot({
    required this.status,
    required this.bytesTransferred,
  });
  final TransferStatus status;
  final int bytesTransferred;

  factory _TransferSnapshot.from(Transfer t) => _TransferSnapshot(
        status: t.status,
        bytesTransferred: t.bytesTransferred,
      );
}
