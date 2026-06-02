import 'in_flight_invite_store.dart';

/// A pair handshake that the persisted mailbox shows was left in flight by
/// a crash/kill mid-confirm — an [InFlightInviteEntry] that survived to the
/// next launch without being removed by any clean exit and is NOT yet
/// expired.
///
/// RESPONDER-SIDE ONLY: the initiator keeps its in-flight pairing state in
/// memory (PairInviteService's `_awaitingResponse` / `_pending` maps) and
/// persists nothing, so an initiator-side crash leaves no marker to
/// recover. The only durable trace of a half-done handshake is this
/// mailbox entry, written by the responder inside `acceptInvite`. See
/// docs/v1/architecture.md transport rule #4 + ux.md pairing rule #4.
class InterruptedPairing {
  const InterruptedPairing({
    required this.inviteId,
    required this.peerName,
    required this.peerId,
  });

  final String inviteId;
  final String peerName;
  final String peerId;
}

/// Boot-time detector: reads the persisted mailbox, classifies a non-expired
/// leftover entry as an interrupted handshake, and consumes (purges) the
/// markers so the prompt is strictly one-shot.
class InterruptedPairingDetector {
  InterruptedPairingDetector(this._mailbox);

  final InFlightInviteStore _mailbox;

  /// One-shot. Returns the most-recent interrupted handshake (an entry with
  /// `now < expiresAt`) or null, and PURGES every leftover entry it
  /// inspects — interrupted *and* already-expired — so a second call (or a
  /// later session) never re-surfaces the same prompt. Classifying an entry
  /// with `now >= expiresAt` as expired-not-interrupted is the exact
  /// interrupted-vs-clean boundary the docs require, and it agrees with
  /// [InFlightInviteStore.purgeExpired]'s `!now.isBefore(expiresAt)`
  /// predicate. `remove()` is a no-op for ids already gone.
  Future<InterruptedPairing?> detectAndConsume(DateTime now) async {
    final all = await _mailbox.readAll();
    if (all.isEmpty) return null;

    InFlightInviteEntry? interrupted;
    for (final e in all.values) {
      final isExpired = !now.isBefore(e.expiresAt); // now >= expiresAt
      if (isExpired) continue;
      // Prefer the latest-expiring (freshest) survivor if several exist.
      if (interrupted == null || e.expiresAt.isAfter(interrupted.expiresAt)) {
        interrupted = e;
      }
    }

    // Consume: purge ALL leftover entries we saw (interrupted + expired) so
    // the prompt is strictly one-shot and the mailbox is clean for the new
    // session.
    for (final id in all.keys.toList()) {
      await _mailbox.remove(id);
    }

    if (interrupted == null) return null;
    return InterruptedPairing(
      inviteId: interrupted.inviteId,
      peerName: interrupted.peerName,
      peerId: interrupted.peerId,
    );
  }
}
