/// Slice 5.2.1: notification channel + id constants shared by the
/// platform notification plumbing and the coordinator that dispatches
/// into it. Channels are created eagerly at app init so the first
/// transfer doesn't pay the channel-create round-trip on its hot path.
library;

/// Persistent ambient notification kept up by the Android foreground
/// service while paired count > 0 (slice 5.2.2). `IMPORTANCE_MIN` so it
/// collapses to a single line at the bottom of the shade — silent, no
/// peek, no lock-screen presence. Created in 5.2.1 to keep all channel
/// declarations in one place; first emission is in 5.2.2.
class IdleChannel {
  static const id = 'service_idle';
  static const name = 'Sharer running';
  static const description =
      'Shown while Sharer is listening for incoming files. Long-press '
      'this notification to mute the channel — the app will keep '
      'listening, the OS just stops showing the indicator.';
}

/// Heads-up + progress while a transfer is in flight. `IMPORTANCE_LOW`
/// because we want the heads-up on first show but the progress updates
/// shouldn't keep waking the screen.
class TransferActiveChannel {
  static const id = 'transfer_active';
  static const name = 'Incoming transfer';
  static const description = 'Progress for files being received.';
}

/// One-shot completion / failure toast. `IMPORTANCE_DEFAULT` so it
/// makes a sound — the user wants to know the file's ready.
class TransferDoneChannel {
  static const id = 'transfer_done';
  static const name = 'Transfer finished';
  static const description = 'A file finished downloading or failed.';
}

/// Pair-invite arrived from a nearby device. `IMPORTANCE_HIGH` because
/// the user has 5 minutes (the invite TTL) to act; missing this is the
/// difference between pairing and not.
class PairInviteChannel {
  static const id = 'pair_invite';
  static const name = 'Pair requests';
  static const description =
      'Another device on this Wi-Fi wants to pair with Sharer.';
}

/// Slice 5.2.4: stable action ids embedded in notification action
/// buttons. The plugin echoes these back via [NotificationResponse.actionId]
/// when the user taps a button so the router can dispatch.
class NotificationActions {
  /// Transfer-done notification → "Open" → launches the saved file in
  /// the OS default handler.
  static const transferOpen = 'transfer_open';

  /// Pair-invite notification → "View" → opens the fingerprint modal.
  /// Body taps route to the same place; the explicit button gives a
  /// keyboard / accessibility-friendly target.
  static const inviteView = 'invite_view';

  /// Pair-invite notification → "Decline" → invokes the decline flow
  /// without opening any UI. The user gets to refuse a pairing
  /// request straight from the lock screen.
  static const inviteReject = 'invite_reject';
}

/// Notification id namespacing. Keep them in disjoint integer ranges so
/// a transfer-active and a pair-invite for the same string id don't
/// collide on `cancel(id)`.
class NotificationIdSpace {
  /// Idle/foreground-service notification — exactly one at a time.
  static const idle = 1;

  static int transferActive(String transferId) =>
      _hashIntoRange(transferId, base: 0x0100_0000, span: 0x00FF_FFFF);

  static int transferDone(String transferId) =>
      _hashIntoRange(transferId, base: 0x0200_0000, span: 0x00FF_FFFF);

  static int pairInvite(String inviteId) =>
      _hashIntoRange(inviteId, base: 0x0300_0000, span: 0x00FF_FFFF);

  /// FNV-1a 32-bit, then folded into [base, base+span). Deterministic
  /// across runs for the same input string — important because cold
  /// boots can mean we need to reconstruct the same id.
  static int _hashIntoRange(String s, {required int base, required int span}) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = (h ^ c) & 0xFFFFFFFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return base + (h % span);
  }
}
