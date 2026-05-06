import 'dart:convert';

import 'secure_key_value_store.dart';

/// Slice 5.2.4.2 — persistent mailbox of in-flight pair invites used
/// by the background notification handler.
///
/// When the user taps **Decline** on a pair-invite notification while
/// the app's main Dart isolate is dead (Android suspended the app, or
/// the app was launched cold from the lock screen), Android dispatches
/// the action to a *separate* background isolate via
/// `onDidReceiveBackgroundNotificationResponse`. That isolate has no
/// access to the in-memory `_pending` map [PairInviteService] keeps,
/// and it cannot derive the per-pair PSK from scratch (the PSK is
/// itself in-memory). So the responder side, when it accepts an
/// invite, **also** persists everything the BG handler needs:
///
///   - inviteId
///   - peer routing (host:port + cert fingerprint for TLS pinning)
///   - sender id (the local deviceId — stable, but it's free to
///     persist alongside everything else)
///   - the **pre-signed decline payload** (HMAC of the decline
///     canonical with the per-pair PSK). The BG handler doesn't have
///     to reach the PSK; it just POSTs the bytes.
///   - expiresAt so cleanup of stale entries is bounded.
///
/// On any of: pair commit, local decline (in foreground), peer
/// decline, expiry — the entry is deleted from the mailbox so the
/// BG handler can't trigger a redundant POST.
///
/// Single secure-storage key, JSON map keyed by inviteId. Read-modify-
/// write. We don't expect more than ~5 concurrent in-flight invites,
/// so the cost of rewriting the whole map is fine.

class InFlightInviteEntry {
  const InFlightInviteEntry({
    required this.inviteId,
    required this.peerId,
    required this.peerName,
    required this.peerHost,
    required this.peerPort,
    required this.peerCertFingerprint,
    required this.senderId,
    required this.declineSignatureBase64,
    required this.expiresAt,
  });

  final String inviteId;
  final String peerId;
  final String peerName;
  final String peerHost;
  final int peerPort;
  final String peerCertFingerprint;
  final String senderId;
  final String declineSignatureBase64;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
        'inviteId': inviteId,
        'peerId': peerId,
        'peerName': peerName,
        'peerHost': peerHost,
        'peerPort': peerPort,
        'peerCertFingerprint': peerCertFingerprint,
        'senderId': senderId,
        'declineSignatureBase64': declineSignatureBase64,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static InFlightInviteEntry? tryFromJson(Map<String, dynamic> j) {
    try {
      return InFlightInviteEntry(
        inviteId: j['inviteId'] as String,
        peerId: j['peerId'] as String,
        peerName: j['peerName'] as String,
        peerHost: j['peerHost'] as String,
        peerPort: j['peerPort'] as int,
        peerCertFingerprint: j['peerCertFingerprint'] as String,
        senderId: j['senderId'] as String,
        declineSignatureBase64: j['declineSignatureBase64'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

class InFlightInviteStore {
  static const _storageKey = 'in_flight_invites_v1';

  InFlightInviteStore(this._secure);

  final SecureKeyValueStore _secure;

  Future<Map<String, InFlightInviteEntry>> _readAll() async {
    final raw = await _secure.read(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, InFlightInviteEntry>{};
      decoded.forEach((id, value) {
        if (value is! Map) return;
        final entry =
            InFlightInviteEntry.tryFromJson(value.cast<String, dynamic>());
        if (entry != null) out[id] = entry;
      });
      return out;
    } catch (_) {
      // Corrupt blob — drop everything. Pair invites are transient
      // anyway; worst case is a single decline that fails to fire.
      return {};
    }
  }

  Future<void> _writeAll(Map<String, InFlightInviteEntry> entries) async {
    if (entries.isEmpty) {
      await _secure.delete(_storageKey);
      return;
    }
    final encoded =
        jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson())));
    await _secure.write(_storageKey, encoded);
  }

  Future<void> save(InFlightInviteEntry entry) async {
    final all = await _readAll();
    all[entry.inviteId] = entry;
    await _writeAll(all);
  }

  Future<InFlightInviteEntry?> get(String inviteId) async {
    final all = await _readAll();
    return all[inviteId];
  }

  Future<void> remove(String inviteId) async {
    final all = await _readAll();
    if (all.remove(inviteId) == null) return;
    await _writeAll(all);
  }

  /// Drop entries past their TTL. Cheap; called opportunistically by
  /// PairInviteService's expiry sweep.
  Future<void> purgeExpired(DateTime now) async {
    final all = await _readAll();
    final expired =
        all.entries.where((e) => !now.isBefore(e.value.expiresAt)).toList();
    if (expired.isEmpty) return;
    for (final e in expired) {
      all.remove(e.key);
    }
    await _writeAll(all);
  }
}
