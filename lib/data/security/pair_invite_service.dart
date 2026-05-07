import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:cryptography_plus/cryptography_plus.dart' hide Hmac;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/paired_device.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import '../transport/transport_protocol.dart';
import 'dh_handshake.dart';
import 'in_flight_invite_store.dart';
import 'long_term_signer.dart';

/// Verb constants used in canonical-string framing for the slice 4.6
/// LAN pair-invite handshake. Distinct verbs per direction so a sig
/// produced by one side cannot be replayed as the other.
const String _verbInvite = 'sharer-pair-invite-v1';
const String _verbInviteResp = 'sharer-pair-invite-resp-v1';
const String _verbFinalize = 'sharer-pair-finalize-v1';

const Duration _defaultInviteTtl = Duration(minutes: 5);

/// "1-hour decline cooldown" from docs/v1/security.md §6 — after the
/// local user explicitly declines, ignore further invites from the
/// same source-deviceId for this long. Memory-only; process restart
/// wipes it, which is acceptable.
const Duration _defaultDeclineCooldown = Duration(hours: 1);

// ---- Result sealed types -----------------------------------------------

/// Outcome of POST /pair-invite, surfaced to the HTTP handler so it can
/// pick the right status code.
sealed class PairInviteAcceptResult {}

class PairInviteAccepted extends PairInviteAcceptResult {
  PairInviteAccepted({
    required this.responderEphemeralPublicKey,
    required this.responderPublicKey,
    required this.responderCertFingerprintSha256,
    required this.responderId,
    required this.responderName,
    required this.signature,
    required this.expiresAt,
  });

  final Uint8List responderEphemeralPublicKey;
  final Uint8List responderPublicKey;
  final String responderCertFingerprintSha256;
  final String responderId;
  final String responderName;
  final Uint8List signature;
  final DateTime expiresAt;
}

class PairInviteRejected extends PairInviteAcceptResult {
  PairInviteRejected(this.reason);
  final String reason;
}

class PairInviteRateLimited extends PairInviteAcceptResult {
  PairInviteRateLimited(this.reason);
  final String reason;
}

/// Outcome of POST /pair-finalize.
sealed class PairFinalizeResult {}

class PairFinalizeRecorded extends PairFinalizeResult {}

class PairFinalizeUnknown extends PairFinalizeResult {}

class PairFinalizeRejected extends PairFinalizeResult {
  PairFinalizeRejected(this.reason);
  final String reason;
}

/// Outcome of [PairInviteService.completeInvite] on the initiator side.
sealed class PairInviteCompleteResult {}

class PairInviteReady extends PairInviteCompleteResult {
  PairInviteReady(this.invite);
  final PairInvite invite;
}

class PairInviteCompleteRejected extends PairInviteCompleteResult {
  PairInviteCompleteRejected(this.reason);
  final String reason;
}

// ---- Internal in-flight bookkeeping ------------------------------------

class _Pending {
  _Pending({
    required this.inviteId,
    required this.role,
    required this.peerId,
    required this.peerName,
    required this.peerLongTermPublicKey,
    required this.peerEphemeralPublicKey,
    required this.peerCertFingerprint,
    required this.myEphemeralKeyPair,
    required this.myEphemeralPublicKey,
    required this.psk,
    required this.fingerprint,
    required this.expiresAt,
    this.peerHost,
  });

  final String inviteId;
  final PairInviteRole role;
  final String peerId;
  String peerName;
  final Uint8List peerLongTermPublicKey;
  final Uint8List peerEphemeralPublicKey;
  /// Slice 5.1: peer's TLS cert fingerprint, persisted onto
  /// PairedDevice on commit so future hot-path /upload requests pin
  /// against it.
  final String peerCertFingerprint;
  final SimpleKeyPair myEphemeralKeyPair;
  final Uint8List myEphemeralPublicKey;
  final Uint8List psk;
  final String fingerprint;
  final DateTime expiresAt;

  /// Slice 5.1.2: on the **responder** side, the IP we observed the
  /// initiator's `/pair-invite` POST coming *from* (URL-safe — IPv6
  /// already wrapped in brackets). Preferred over `peer.host` from
  /// mDNS when posting `/pair-finalize` back, because mDNS-resolved
  /// hostnames on Windows (`Android_AOJYSW9X.local`) can route via the
  /// wrong network interface and time out (real-device pairing freeze
  /// caught during slice 5.2.1 validation).
  String? peerHost;

  bool localMatched = false;
  bool localDeclined = false;
  bool peerMatched = false;
  bool peerDeclined = false;
  bool committed = false;
}

/// Slim record kept on the initiator between [createInvite] and
/// [completeInvite] — we don't have the peer's ephemeral pubkey yet,
/// so we can't derive the PSK or fingerprint. Once the response comes
/// back this gets promoted to a [_Pending].
class _InitiatorAwaitingResponse {
  _InitiatorAwaitingResponse({
    required this.inviteId,
    required this.responderId,
    required this.myEphemeralKeyPair,
    required this.myEphemeralPublicKey,
    required this.myCertFingerprint,
    required this.expiresAt,
  });

  final String inviteId;
  final String responderId;
  final SimpleKeyPair myEphemeralKeyPair;
  final Uint8List myEphemeralPublicKey;
  final String myCertFingerprint;
  final DateTime expiresAt;
}

/// Coordinates the slice 4.6 LAN pair-invite handshake on both sides.
///
/// **Initiator** (A taps an unpaired peer in the nearby list):
///
/// 1. [createInvite] — mint inviteId, ephemeral X25519, sign canonical.
/// 2. App posts payload to B's /pair-invite via [PairInviteClient].
/// 3. [completeInvite] — feed B's response back; service verifies B's
///    Ed25519 sig, derives PSK, surfaces a [PairInvite] on [invites].
///
/// **Responder** (B's HTTP server received /pair-invite):
///
/// 1. [acceptInvite] — verify A's Ed25519 + identity binding, generate
///    own X25519, derive PSK, surface a [PairInvite] on [invites], and
///    return the response payload for the HTTP handler to send back.
///
/// **Both sides** then show the fingerprint modal:
///
/// - User taps "Matches" → [markLocalMatched] flips local flag and
///   returns the bytes the [PairInviteClient] should POST as the
///   /pair-finalize match verdict.
/// - User taps "Doesn't match" / closes → [markLocalDeclined] sends a
///   /pair-finalize decline.
/// - Peer's POST arrives → [recordRemoteFinalize].
///
/// The pair commits exactly once, when both sides have matched. Either
/// side declining (or expiry) discards the in-flight state whole.
class PairInviteService {
  static const String _logName = 'sharer.security.invite';

  PairInviteService(
    this._paired,
    this._identity, {
    InFlightInviteStore? mailbox,
    Random? random,
    DateTime Function()? now,
    Uuid? uuid,
    Duration inviteTtl = _defaultInviteTtl,
    Duration declineCooldown = _defaultDeclineCooldown,
    Duration expirySweepInterval = const Duration(seconds: 30),
  })  : _mailbox = mailbox,
        _random = random ?? Random.secure(),
        _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid(),
        _inviteTtl = inviteTtl,
        _declineCooldown = declineCooldown {
    // Slice 5.1.2: without a periodic sweep, an in-flight invite whose
    // peer goes silent (e.g. the responder's reciprocal /pair-finalize
    // never arrives) leaves the modal open forever — _purgeExpired()
    // only runs when a state-mutating method is called. The timer is
    // cheap (a single map walk per tick) and shuts down on dispose.
    _expirySweep =
        Timer.periodic(expirySweepInterval, (_) => _purgeExpired());
  }

  final PairedDevicesRepository _paired;
  final DeviceIdentityRepository _identity;

  /// Slice 5.2.4.2: when wired, the responder side persists enough
  /// per-invite info that a background-isolate notification handler
  /// can fire a Decline POST without the main isolate being alive.
  /// Optional so test setups don't all have to construct one.
  final InFlightInviteStore? _mailbox;

  final Random _random;
  final DateTime Function() _now;
  final Uuid _uuid;
  final Duration _inviteTtl;
  final Duration _declineCooldown;

  final Map<String, _Pending> _pending = {};
  final Map<String, _InitiatorAwaitingResponse> _awaitingResponse = {};
  final Map<String, DateTime> _declinedAt = {};

  final _invites = StreamController<PairInvite>.broadcast();
  late final Timer _expirySweep;

  /// Stream of [PairInvite] state-machine snapshots. The UI subscribes
  /// to this to show / dismiss the fingerprint-confirm modal.
  Stream<PairInvite> get invites => _invites.stream;

  // ====================================================================
  //  Initiator side
  // ====================================================================

  /// Step 1 (initiator). Mint a fresh invite payload to be POSTed to
  /// the responder's /pair-invite. The X25519 ephemeral key is held
  /// in-process — we cannot finish the handshake if the app is killed.
  ///
  /// [localCertFingerprintSha256] is the initiator's TLS server cert
  /// fingerprint (slice 5.1) — covered by the Ed25519 sig and embedded
  /// in the payload so the responder can persist it on the resulting
  /// [PairedDevice] for hot-path /upload pinning.
  Future<({
    String inviteId,
    String initiatorId,
    String initiatorName,
    Uint8List initiatorPublicKey,
    Uint8List initiatorEphemeralPublicKey,
    String initiatorCertFingerprintSha256,
    Uint8List nonce,
    Uint8List signature,
    DateTime expiresAt,
  })> createInvite({
    required String responderId,
    required String localCertFingerprintSha256,
  }) async {
    _purgeExpired();
    final identity = await _identity.get();
    final ephemeral = await EphemeralX25519KeyPair.generate();
    final inviteId = _uuid.v4();
    final nonce = _randomBytes(16);
    final expiresAt = _now().add(_inviteTtl);
    final canonical = _inviteCanonical(
      inviteId: inviteId,
      initiatorId: identity.id,
      responderId: responderId,
      initiatorEphemeralPublicKey: ephemeral.publicKey,
      initiatorCertFingerprintSha256: localCertFingerprintSha256,
      nonce: nonce,
      expiresAt: expiresAt,
    );
    final signature = await _identity.sign(canonical);
    _awaitingResponse[inviteId] = _InitiatorAwaitingResponse(
      inviteId: inviteId,
      responderId: responderId,
      myEphemeralKeyPair: ephemeral.keyPair,
      myEphemeralPublicKey: ephemeral.publicKey,
      myCertFingerprint: localCertFingerprintSha256,
      expiresAt: expiresAt,
    );
    _log('createInvite id=$inviteId responder=$responderId');
    return (
      inviteId: inviteId,
      initiatorId: identity.id,
      initiatorName: identity.name,
      initiatorPublicKey: identity.publicKey,
      initiatorEphemeralPublicKey: ephemeral.publicKey,
      initiatorCertFingerprintSha256: localCertFingerprintSha256,
      nonce: nonce,
      signature: Uint8List.fromList(signature),
      expiresAt: expiresAt,
    );
  }

  /// Step 3 (initiator). After the network POST returns 200 with the
  /// responder's payload, feed it back here. On success a [PairInvite]
  /// is emitted on [invites] with status = awaitingFingerprint.
  Future<PairInviteCompleteResult> completeInvite({
    required String inviteId,
    required String responderId,
    required String responderName,
    required Uint8List responderPublicKey,
    required Uint8List responderEphemeralPublicKey,
    required String responderCertFingerprintSha256,
    required Uint8List signature,
  }) async {
    _purgeExpired();
    final pending = _awaitingResponse.remove(inviteId);
    if (pending == null) {
      _log('completeInvite reject: unknown id=$inviteId');
      return PairInviteCompleteRejected('unknown invite');
    }
    if (responderPublicKey.length != 32 ||
        responderEphemeralPublicKey.length != 32) {
      _log('completeInvite reject: bad key length id=$inviteId');
      return PairInviteCompleteRejected('bad key length');
    }
    if (LongTermSigner.fingerprintOf(responderPublicKey) != responderId) {
      _log('completeInvite reject: deviceId/publicKey mismatch id=$inviteId');
      return PairInviteCompleteRejected('identity mismatch');
    }
    if (responderId != pending.responderId) {
      _log('completeInvite reject: responder identity changed id=$inviteId');
      return PairInviteCompleteRejected('responder mismatch');
    }
    if (responderCertFingerprintSha256.isEmpty) {
      _log('completeInvite reject: missing cert fingerprint id=$inviteId');
      return PairInviteCompleteRejected('missing cert fingerprint');
    }
    final canonical = _responseCanonical(
      inviteId: inviteId,
      responderId: responderId,
      responderEphemeralPublicKey: responderEphemeralPublicKey,
      responderCertFingerprintSha256: responderCertFingerprintSha256,
      initiatorEphemeralPublicKey: pending.myEphemeralPublicKey,
    );
    final ok = await LongTermSigner.verify(
      message: canonical,
      signature: signature,
      publicKey: responderPublicKey,
    );
    if (!ok) {
      _log('completeInvite reject: signature mismatch id=$inviteId');
      return PairInviteCompleteRejected('bad signature');
    }
    final psk = await derivePairPsk(
      myEphemeralKeyPair: pending.myEphemeralKeyPair,
      peerEphemeralPublicKey: responderEphemeralPublicKey,
      initiatorEphemeralPublicKey: pending.myEphemeralPublicKey,
      responderEphemeralPublicKey: responderEphemeralPublicKey,
    );
    final fingerprint = pairFingerprint(psk);
    final entry = _Pending(
      inviteId: inviteId,
      role: PairInviteRole.initiator,
      peerId: responderId,
      peerName: responderName,
      peerLongTermPublicKey: responderPublicKey,
      peerEphemeralPublicKey: responderEphemeralPublicKey,
      peerCertFingerprint: responderCertFingerprintSha256,
      myEphemeralKeyPair: pending.myEphemeralKeyPair,
      myEphemeralPublicKey: pending.myEphemeralPublicKey,
      psk: psk,
      fingerprint: fingerprint,
      expiresAt: pending.expiresAt,
    );
    _pending[inviteId] = entry;
    final invite = _toInvite(entry, PairInviteStatus.awaitingFingerprint);
    _invites.add(invite);
    _log('completeInvite ready id=$inviteId fingerprint=$fingerprint');
    return PairInviteReady(invite);
  }

  // ====================================================================
  //  Responder side
  // ====================================================================

  /// Step 2 (responder). Called by the HTTP handler when /pair-invite
  /// arrives. Validates the initiator's Ed25519 sig, then on success
  /// derives the PSK and returns the bytes the handler will send back.
  ///
  /// [initiatorCertFingerprintSha256] — what the initiator claims their
  /// TLS server cert fingerprint is. Covered by the initiator's
  /// signature; persisted on the resulting [PairedDevice] for hot-path
  /// /upload pinning.
  ///
  /// [localCertFingerprintSha256] — the responder's own TLS cert
  /// fingerprint, included in the response payload + signature so the
  /// initiator can pin us in turn.
  Future<PairInviteAcceptResult> acceptInvite({
    required String inviteId,
    required String initiatorId,
    required String initiatorName,
    required Uint8List initiatorPublicKey,
    required Uint8List initiatorEphemeralPublicKey,
    required String initiatorCertFingerprintSha256,
    required Uint8List nonce,
    required Uint8List signature,
    required DateTime expiresAt,
    required String localCertFingerprintSha256,
    String? initiatorRemoteHost,
  }) async {
    _purgeExpired();

    if (initiatorPublicKey.length != 32 ||
        initiatorEphemeralPublicKey.length != 32) {
      _log('acceptInvite reject: bad key length id=$inviteId');
      return PairInviteRejected('bad key length');
    }
    if (LongTermSigner.fingerprintOf(initiatorPublicKey) != initiatorId) {
      _log('acceptInvite reject: deviceId/publicKey mismatch id=$inviteId');
      return PairInviteRejected('identity mismatch');
    }
    if (initiatorCertFingerprintSha256.isEmpty) {
      _log('acceptInvite reject: missing cert fingerprint id=$inviteId');
      return PairInviteRejected('missing cert fingerprint');
    }

    // Cooldown after a previous local decline from this peer.
    final cooldownUntil = _declinedAt[initiatorId];
    if (cooldownUntil != null &&
        _now().isBefore(cooldownUntil.add(_declineCooldown))) {
      _log('acceptInvite rate-limit (decline cooldown) peer=$initiatorId');
      return PairInviteRateLimited('decline cooldown');
    }

    // One pending invite per source deviceId.
    final existing = _pending.values
        .where((p) =>
            p.peerId == initiatorId && p.role == PairInviteRole.responder)
        .firstOrNull;
    if (existing != null) {
      _log('acceptInvite rate-limit (already pending) peer=$initiatorId '
          'existingInviteId=${existing.inviteId}');
      return PairInviteRateLimited('invite already pending');
    }

    final identity = await _identity.get();

    final canonical = _inviteCanonical(
      inviteId: inviteId,
      initiatorId: initiatorId,
      responderId: identity.id,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: initiatorCertFingerprintSha256,
      nonce: nonce,
      expiresAt: expiresAt,
    );
    final ok = await LongTermSigner.verify(
      message: canonical,
      signature: signature,
      publicKey: initiatorPublicKey,
    );
    if (!ok) {
      _log('acceptInvite reject: signature mismatch id=$inviteId');
      return PairInviteRejected('bad signature');
    }

    final myEphemeral = await EphemeralX25519KeyPair.generate();
    final psk = await derivePairPsk(
      myEphemeralKeyPair: myEphemeral.keyPair,
      peerEphemeralPublicKey: initiatorEphemeralPublicKey,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
      responderEphemeralPublicKey: myEphemeral.publicKey,
    );
    final fingerprint = pairFingerprint(psk);

    final responseCanonical = _responseCanonical(
      inviteId: inviteId,
      responderId: identity.id,
      responderEphemeralPublicKey: myEphemeral.publicKey,
      responderCertFingerprintSha256: localCertFingerprintSha256,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
    );
    final mySignature =
        Uint8List.fromList(await _identity.sign(responseCanonical));

    final entry = _Pending(
      inviteId: inviteId,
      role: PairInviteRole.responder,
      peerId: initiatorId,
      peerName: initiatorName,
      peerLongTermPublicKey: initiatorPublicKey,
      peerEphemeralPublicKey: initiatorEphemeralPublicKey,
      peerCertFingerprint: initiatorCertFingerprintSha256,
      myEphemeralKeyPair: myEphemeral.keyPair,
      myEphemeralPublicKey: myEphemeral.publicKey,
      psk: psk,
      fingerprint: fingerprint,
      expiresAt: expiresAt.isBefore(_now().add(_inviteTtl))
          ? expiresAt
          : _now().add(_inviteTtl),
      peerHost: initiatorRemoteHost,
    );
    _pending[inviteId] = entry;

    // Slice 5.2.4.2: persist a pre-signed decline payload so the
    // background notification handler can fire Decline even when the
    // main isolate is dead. Best-effort — if the mailbox isn't wired
    // (tests, no secure storage available) we just lose the silent-
    // decline path. The foreground decline path is unaffected.
    if (_mailbox != null && initiatorRemoteHost != null) {
      final declineCanonical = _finalizeCanonical(
        inviteId: inviteId,
        senderId: identity.id,
        verdict: 'decline',
      );
      final declineMac = Hmac(sha256, psk).convert(declineCanonical);
      try {
        await _mailbox.save(InFlightInviteEntry(
          inviteId: inviteId,
          peerId: initiatorId,
          peerName: initiatorName,
          peerHost: initiatorRemoteHost,
          peerPort: TransportProtocol.defaultPort,
          peerCertFingerprint: initiatorCertFingerprintSha256,
          senderId: identity.id,
          declineSignatureBase64: base64Encode(declineMac.bytes),
          expiresAt: entry.expiresAt,
        ));
      } catch (e) {
        _log('mailbox.save failed id=$inviteId: $e (BG decline disabled)');
      }
    }

    _invites.add(_toInvite(entry, PairInviteStatus.awaitingFingerprint));
    _log('acceptInvite OK id=$inviteId from=$initiatorId '
        'fingerprint=$fingerprint');

    return PairInviteAccepted(
      responderEphemeralPublicKey: myEphemeral.publicKey,
      responderPublicKey: identity.publicKey,
      responderCertFingerprintSha256: localCertFingerprintSha256,
      responderId: identity.id,
      responderName: identity.name,
      signature: mySignature,
      expiresAt: entry.expiresAt,
    );
  }

  // ====================================================================
  //  Finalize (both sides)
  // ====================================================================

  /// Local user tapped "Matches". Flips the in-flight flag and returns
  /// the canonical bytes + HMAC the [PairInviteClient] will POST as the
  /// /pair-finalize match verdict. If the peer already POSTed match,
  /// the pair is committed here and the returned future emits the
  /// stored device.
  ///
  /// Always emits a stream event so the modal can disable the Matches
  /// button between "user tapped" and "peer confirmed":
  ///   - peer not yet matched → emit [PairInviteStatus.localMatched]
  ///   - peer already matched → [_maybeCommit] emits
  ///     [PairInviteStatus.completed] and removes the entry
  /// Real-device validation (slice 5.2.1) caught the bug where this
  /// method silently flipped the flag without emitting — the modal
  /// re-enabled the button after the network round-trip and the user
  /// could re-tap into a 404 cascade.
  Future<({Uint8List canonical, String signatureBase64})?> markLocalMatched(
    String inviteId,
  ) async {
    _purgeExpired();
    final p = _pending[inviteId];
    if (p == null) {
      _log('markLocalMatched no-op: unknown id=$inviteId');
      return null;
    }
    if (p.localDeclined || p.peerDeclined) {
      _log('markLocalMatched no-op: already declined id=$inviteId');
      return null;
    }
    p.localMatched = true;
    final identity = await _identity.get();
    final canonical = _finalizeCanonical(
      inviteId: inviteId,
      senderId: identity.id,
      verdict: 'match',
    );
    final mac = Hmac(sha256, p.psk).convert(canonical);
    if (!p.peerMatched) {
      // Surface the new state so the modal flips into "waiting for peer
      // to confirm" and the button stays disabled.
      _invites.add(_toInvite(p, PairInviteStatus.localMatched));
    }
    await _maybeCommit(p);
    return (
      canonical: Uint8List.fromList(canonical),
      signatureBase64: base64Encode(mac.bytes),
    );
  }

  /// Local user tapped "Doesn't match" or closed the modal. Returns the
  /// canonical + HMAC for the decline POST (so the peer can roll back
  /// immediately) and discards the in-flight state.
  Future<({Uint8List canonical, String signatureBase64})?> markLocalDeclined(
    String inviteId,
  ) async {
    final p = _pending[inviteId];
    if (p == null) return null;
    p.localDeclined = true;
    _declinedAt[p.peerId] = _now();
    final identity = await _identity.get();
    final canonical = _finalizeCanonical(
      inviteId: inviteId,
      senderId: identity.id,
      verdict: 'decline',
    );
    final mac = Hmac(sha256, p.psk).convert(canonical);
    _pending.remove(inviteId);
    await _mailbox?.remove(inviteId);
    _invites.add(_toInvite(p, PairInviteStatus.declined));
    _log('markLocalDeclined id=$inviteId peer=${p.peerId}');
    return (
      canonical: Uint8List.fromList(canonical),
      signatureBase64: base64Encode(mac.bytes),
    );
  }

  /// Step (final). Called by the HTTP handler when /pair-finalize
  /// arrives from the peer. On a match-with-local-already-matched, the
  /// pair is stored.
  Future<PairFinalizeResult> recordRemoteFinalize({
    required String inviteId,
    required String senderId,
    required String verdict,
    required String signatureBase64,
  }) async {
    _purgeExpired();
    final p = _pending[inviteId];
    if (p == null) {
      _log('recordRemoteFinalize unknown id=$inviteId');
      return PairFinalizeUnknown();
    }
    if (senderId != p.peerId) {
      _log('recordRemoteFinalize reject: senderId mismatch id=$inviteId '
          'expected=${p.peerId} got=$senderId');
      return PairFinalizeRejected('sender mismatch');
    }
    if (verdict != 'match' && verdict != 'decline') {
      return PairFinalizeRejected('bad verdict');
    }
    Uint8List? sigBytes;
    try {
      sigBytes = Uint8List.fromList(base64Decode(signatureBase64));
    } catch (_) {
      return PairFinalizeRejected('bad signature encoding');
    }
    final canonical = _finalizeCanonical(
      inviteId: inviteId,
      senderId: senderId,
      verdict: verdict,
    );
    final expected = Hmac(sha256, p.psk).convert(canonical);
    if (!_constantTimeEquals(expected.bytes, sigBytes)) {
      _log('recordRemoteFinalize reject: HMAC mismatch id=$inviteId');
      return PairFinalizeRejected('bad signature');
    }

    if (verdict == 'decline') {
      p.peerDeclined = true;
      _pending.remove(inviteId);
      await _mailbox?.remove(inviteId);
      _invites.add(_toInvite(p, PairInviteStatus.declined));
      _log('recordRemoteFinalize: peer declined id=$inviteId');
      return PairFinalizeRecorded();
    }
    p.peerMatched = true;
    await _maybeCommit(p);
    return PairFinalizeRecorded();
  }

  /// Returns the peer's TLS cert fingerprint as captured during the
  /// handshake, so the [InviteController] can pin /pair-finalize POSTs
  /// against the same cert. Null when no in-flight entry matches.
  String? peerCertFingerprintFor(String inviteId) =>
      _pending[inviteId]?.peerCertFingerprint;

  /// Slice 5.1.2: returns the URL-safe host string the
  /// [InviteController] should target for /pair-finalize. On the
  /// **responder** side this is the initiator's source IP captured at
  /// HTTP-handler time — preferred over `peer.host` from mDNS, which
  /// on Windows resolves to a `.local` hostname that may not route via
  /// the right interface. On the initiator side this is null (the
  /// initiator already had the responder's IP from mDNS to send the
  /// original /pair-invite).
  String? peerHostFor(String inviteId) => _pending[inviteId]?.peerHost;

  /// Drop the in-flight invite without sending anything. Used when the
  /// initiator's POST /pair-invite failed at the network layer (peer
  /// unreachable, HTTP error, decline) — no sense keeping ephemeral
  /// state we can never finish.
  void abandon(String inviteId) {
    _awaitingResponse.remove(inviteId);
    final p = _pending.remove(inviteId);
    if (p != null) {
      _invites.add(_toInvite(p, PairInviteStatus.declined));
    }
    // Best-effort mailbox cleanup. Fire-and-forget — abandon is sync.
    unawaited(_mailbox?.remove(inviteId) ?? Future.value());
    _log('abandon id=$inviteId');
  }

  Future<void> dispose() async {
    _expirySweep.cancel();
    await _invites.close();
  }

  // ====================================================================
  //  Internals
  // ====================================================================

  Future<void> _maybeCommit(_Pending p) async {
    if (p.committed) return;
    if (!p.localMatched || !p.peerMatched) return;
    final paired = PairedDevice(
      deviceId: p.peerId,
      displayName: p.peerName,
      psk: p.psk,
      publicKey: p.peerLongTermPublicKey,
      certFingerprint: p.peerCertFingerprint,
      pairedAt: _now(),
    );
    await _paired.add(paired);
    p.committed = true;
    _pending.remove(p.inviteId);
    await _mailbox?.remove(p.inviteId);
    _invites.add(_toInvite(p, PairInviteStatus.completed));
    _log('committed id=${p.inviteId} peer=${p.peerId}');
  }

  void _purgeExpired() {
    final n = _now();
    final expiredAwait = _awaitingResponse.values
        .where((a) => !n.isBefore(a.expiresAt))
        .map((a) => a.inviteId)
        .toList();
    for (final id in expiredAwait) {
      _awaitingResponse.remove(id);
      _log('expired (awaiting response) id=$id');
    }
    final expiredPending = _pending.values
        .where((p) => !n.isBefore(p.expiresAt))
        .toList();
    for (final p in expiredPending) {
      _pending.remove(p.inviteId);
      if (!p.committed) {
        _invites.add(_toInvite(p, PairInviteStatus.expired));
      }
      _log('expired (in flight) id=${p.inviteId} peer=${p.peerId}');
    }
    // Slice 5.2.4.2: trim stale mailbox entries opportunistically. The
    // sweep timer ticks every 30s by default, so the worst case is one
    // BG decline POST that arrives slightly after the peer's TTL has
    // passed — peer side ignores it (5.1.2's expiry sweep). Acceptable.
    if (_mailbox != null && (expiredPending.isNotEmpty || _pending.isEmpty)) {
      unawaited(_mailbox.purgeExpired(n));
    }
  }

  PairInvite _toInvite(_Pending p, PairInviteStatus status) => PairInvite(
        inviteId: p.inviteId,
        peerId: p.peerId,
        peerName: p.peerName,
        fingerprint: p.fingerprint,
        role: p.role,
        status: status,
        expiresAt: p.expiresAt,
      );

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

// ---- Canonical-string framing -----------------------------------------

/// Canonical bytes signed by the initiator's Ed25519 over an invite.
List<int> _inviteCanonical({
  required String inviteId,
  required String initiatorId,
  required String responderId,
  required Uint8List initiatorEphemeralPublicKey,
  required String initiatorCertFingerprintSha256,
  required Uint8List nonce,
  required DateTime expiresAt,
}) {
  return utf8.encode([
    _verbInvite,
    inviteId,
    initiatorId,
    responderId,
    _hex(initiatorEphemeralPublicKey),
    initiatorCertFingerprintSha256,
    _hex(nonce),
    expiresAt.toUtc().toIso8601String(),
  ].join('\n'));
}

/// Canonical bytes signed by the responder's Ed25519 in the response.
List<int> _responseCanonical({
  required String inviteId,
  required String responderId,
  required Uint8List responderEphemeralPublicKey,
  required String responderCertFingerprintSha256,
  required Uint8List initiatorEphemeralPublicKey,
}) {
  return utf8.encode([
    _verbInviteResp,
    inviteId,
    responderId,
    _hex(responderEphemeralPublicKey),
    responderCertFingerprintSha256,
    _hex(initiatorEphemeralPublicKey),
  ].join('\n'));
}

/// Canonical bytes covered by the per-pair PSK HMAC on /pair-finalize.
List<int> _finalizeCanonical({
  required String inviteId,
  required String senderId,
  required String verdict,
}) {
  return utf8.encode([
    _verbFinalize,
    inviteId,
    senderId,
    verdict,
  ].join('\n'));
}

String _hex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

// Public re-exports for tests and the wire client.
List<int> debugInviteCanonical({
  required String inviteId,
  required String initiatorId,
  required String responderId,
  required Uint8List initiatorEphemeralPublicKey,
  required String initiatorCertFingerprintSha256,
  required Uint8List nonce,
  required DateTime expiresAt,
}) =>
    _inviteCanonical(
      inviteId: inviteId,
      initiatorId: initiatorId,
      responderId: responderId,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: initiatorCertFingerprintSha256,
      nonce: nonce,
      expiresAt: expiresAt,
    );

List<int> debugResponseCanonical({
  required String inviteId,
  required String responderId,
  required Uint8List responderEphemeralPublicKey,
  required String responderCertFingerprintSha256,
  required Uint8List initiatorEphemeralPublicKey,
}) =>
    _responseCanonical(
      inviteId: inviteId,
      responderId: responderId,
      responderEphemeralPublicKey: responderEphemeralPublicKey,
      responderCertFingerprintSha256: responderCertFingerprintSha256,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
    );

List<int> debugFinalizeCanonical({
  required String inviteId,
  required String senderId,
  required String verdict,
}) =>
    _finalizeCanonical(
      inviteId: inviteId,
      senderId: senderId,
      verdict: verdict,
    );
