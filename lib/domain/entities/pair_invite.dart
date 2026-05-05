/// One side's view of an in-flight LAN pair-invite handshake (slice 4.6).
/// The UI consumes these to render the fingerprint-confirm modal; the
/// raw ephemeral keys + derived PSK live in the data-layer service so
/// they never leak across the layer boundary.
class PairInvite {
  /// Random id minted by the initiator, echoed in every subsequent
  /// /pair-finalize so both sides can match the verdict to the right
  /// in-flight handshake.
  final String inviteId;

  /// The other device — `peerId` is the long-term Ed25519 fingerprint
  /// (see slice 4.5), `peerName` is whatever they advertise.
  final String peerId;
  final String peerName;

  /// Six-digit decimal fingerprint computed locally over the derived
  /// PSK. Both sides see the same number when no MITM intercepted the
  /// X25519 exchange. UI displays this in the modal-blocking sheet.
  final String fingerprint;

  /// Which side this device is. Only the initiator drove the original
  /// /pair-invite POST; the role does not change the verdict logic but
  /// is useful to surface in the UI ("Pairing with X" vs "X wants to
  /// pair").
  final PairInviteRole role;

  final PairInviteStatus status;

  /// Wall-clock instant after which both sides must discard the
  /// in-flight state regardless of user input. Mirrors the offer TTL
  /// from QR pairing.
  final DateTime expiresAt;

  const PairInvite({
    required this.inviteId,
    required this.peerId,
    required this.peerName,
    required this.fingerprint,
    required this.role,
    required this.status,
    required this.expiresAt,
  });

  PairInvite copyWith({PairInviteStatus? status}) => PairInvite(
        inviteId: inviteId,
        peerId: peerId,
        peerName: peerName,
        fingerprint: fingerprint,
        role: role,
        status: status ?? this.status,
        expiresAt: expiresAt,
      );

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

enum PairInviteRole { initiator, responder }

/// State machine for a single in-flight invite. Transitions:
///
///   awaitingFingerprint → localMatched   (user tapped Matches)
///   awaitingFingerprint → localDeclined  (user tapped Doesn't match)
///   localMatched        → completed      (peer's matching /pair-finalize arrived)
///   any                 → declined       (peer declined OR we declined locally)
///   any                 → expired        (TTL ran out before either commitment)
enum PairInviteStatus {
  /// We have both halves of the X25519 + can show the fingerprint, but
  /// neither side has committed yet.
  awaitingFingerprint,

  /// Local user tapped "Matches"; waiting on the peer's verdict.
  localMatched,

  /// Pairing succeeded on both sides. The pair is in the paired-devices
  /// store; the modal can dismiss.
  completed,

  /// Either local user or peer said "Doesn't match" (or peer never
  /// responded and the invite expired). State has been rolled back.
  declined,

  /// TTL elapsed. Treated like `declined` for UX purposes; surfaced
  /// separately so the UI can say "no response in time" vs "rejected".
  expired,
}
