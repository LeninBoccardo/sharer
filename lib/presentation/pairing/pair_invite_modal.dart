import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/security/dh_handshake.dart';
import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';

/// Modal-blocking fingerprint-confirm sheet for slice 4.6 LAN pair
/// invites. UX rules from docs/v1/ux.md "Pairing UX":
///
///   1. Modal-blocking — no swipe-to-dismiss, no system-back, no
///      tap-outside. Only the two buttons or an explicit Cancel exit.
///   2. No timeout-equals-accept. The TTL is enforced by the service;
///      this widget surfaces the expired status as a rejection.
///   3. Both sides must confirm. The widget closes when the service
///      reports completed OR declined OR expired.
///
/// The widget tracks one [inviteId] for its lifetime — if the service
/// emits a different invite (e.g. a second pair attempt overlaps), it
/// is ignored.
class PairInviteModal extends ConsumerStatefulWidget {
  const PairInviteModal({
    super.key,
    required this.initial,
    this.peer,
  });

  final PairInvite initial;

  /// Optional — used to address /pair-finalize back at the peer when
  /// the local user taps Match / Doesn't match. On the responder side
  /// we don't have a [Peer] from mDNS in hand because the invite came
  /// inbound; we'd resolve via the cached IP / discovery list.
  final Peer? peer;

  static Future<void> show(
    BuildContext context, {
    required PairInvite invite,
    Peer? peer,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: PairInviteModal(initial: invite, peer: peer),
      ),
    );
  }

  @override
  ConsumerState<PairInviteModal> createState() => _PairInviteModalState();
}

class _PairInviteModalState extends ConsumerState<PairInviteModal> {
  late PairInvite _current;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _current = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Listen for service-driven status changes (peer declined, peer
    // matched-and-we-already-matched-so-pair-completed, expired).
    ref.listen(pairInviteStreamProvider, (_, next) {
      next.whenData((updated) {
        if (updated.inviteId != _current.inviteId) return;
        setState(() => _current = updated);
        switch (updated.status) {
          case PairInviteStatus.completed:
            _toastAndClose(
              'Paired with ${updated.peerName}.',
              success: true,
            );
          case PairInviteStatus.declined:
            _toastAndClose('Pairing cancelled.');
          case PairInviteStatus.expired:
            _toastAndClose('Pairing timed out.');
          case PairInviteStatus.awaitingFingerprint:
          case PairInviteStatus.localMatched:
            break;
        }
      });
    });

    final pretty = formatFingerprint(_current.fingerprint);
    final waiting = _current.status == PairInviteStatus.localMatched;

    return AlertDialog(
      title: Text(_current.role == PairInviteRole.initiator
          ? 'Confirm pairing with ${_current.peerName}'
          : '${_current.peerName} wants to pair'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Both screens should show the same number. If they don\'t, '
            'someone may be relaying — tap "Doesn\'t match".',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            // FittedBox + softWrap:false keeps "12 34 56" on one line on
            // narrow phones (real-device caught wrap on a 360dp Realme)
            // while still letting wider screens render it large.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                pretty,
                softWrap: false,
                maxLines: 1,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (waiting)
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Waiting for ${_current.peerName} to confirm…',
                      style: theme.textTheme.bodySmall),
                ),
              ],
            ),
        ],
      ),
      actions: [
        TextButton(
          // Once we're locally-matched the decline path no longer
          // makes sense (the peer may be about to commit on its end);
          // disable to avoid races. Slice 5.1.2: matches the multi-tap
          // hardening on the Matches button.
          onPressed: _busy || waiting ? null : () => _finalize(false),
          child: const Text("Doesn't match"),
        ),
        FilledButton(
          onPressed: _busy || waiting ? null : () => _finalize(true),
          child: const Text('Matches'),
        ),
      ],
    );
  }

  Future<void> _finalize(bool match) async {
    setState(() => _busy = true);
    final controller = ref.read(inviteControllerProvider);
    try {
      await controller.finalize(
        inviteId: _current.inviteId,
        peer: widget.peer,
        match: match,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!match && mounted) {
      // Decline closes immediately; match keeps the modal up while we
      // wait for the peer's verdict.
      _toastAndClose('Pairing cancelled.');
    }
  }

  void _toastAndClose(String message, {bool success = false}) {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
