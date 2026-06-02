import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/long_term_signer.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pair_invite_service.dart';
import 'package:sharer/domain/entities/pair_invite.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

// Stub TLS cert fingerprints for the post-5.1 schema. Pair flows
// treat them as opaque strings; only invariant is "non-empty".
const _idACertFp = 'aa:11:bb:22:cc:33:dd:44:ee:55:ff:66:'
    '00:77:11:88:22:99:33:aa:44:bb:55:cc:'
    '66:dd:77:ee:88:ff:99:00';
const _idBCertFp = '11:aa:22:bb:33:cc:44:dd:55:ee:66:ff:'
    '77:00:88:11:99:22:aa:33:bb:44:cc:55:'
    'dd:66:ee:77:ff:88:00:99';

/// End-to-end exerciser for the slice 4.6 LAN pair-invite handshake.
/// Runs two [PairInviteService]s in process — A as initiator, B as
/// responder — and pumps payloads between them as the wire would.
void main() {
  late FakeSecureKeyValueStore secureA;
  late FakeSecureKeyValueStore secureB;
  late PairedDevicesStore pairedA;
  late PairedDevicesStore pairedB;
  late StaticIdentityRepo idA;
  late StaticIdentityRepo idB;
  late DateTime now;
  late PairInviteService a;
  late PairInviteService b;

  setUp(() async {
    secureA = FakeSecureKeyValueStore();
    secureB = FakeSecureKeyValueStore();
    pairedA = PairedDevicesStore(secureA);
    pairedB = PairedDevicesStore(secureB);
    idA = await StaticIdentityRepo.create(seed: 1, name: 'Lenin-PC');
    idB = await StaticIdentityRepo.create(seed: 2, name: 'Realme');
    now = DateTime.utc(2026, 5, 4, 12);
    a = PairInviteService(
      pairedA,
      idA,
      random: Random(0),
      now: () => now,
    );
    b = PairInviteService(
      pairedB,
      idB,
      random: Random(1),
      now: () => now,
    );
  });

  tearDown(() async {
    await a.dispose();
    await b.dispose();
    await pairedA.dispose();
    await pairedB.dispose();
  });

  /// Drives one full A → B → A handshake up to the point where both
  /// sides have a [PairInviteStatus.awaitingFingerprint]. Returns the
  /// pair of invites surfaced on either side's [invites] stream.
  Future<({PairInvite aInvite, PairInvite bInvite, String inviteId})>
      runHandshake() async {
    final emittedA = <PairInvite>[];
    final emittedB = <PairInvite>[];
    final subA = a.invites.listen(emittedA.add);
    final subB = b.invites.listen(emittedB.add);

    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final accepted = await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(accepted, isA<PairInviteAccepted>(),
        reason: 'B should have accepted A\'s invite');
    final ok = accepted as PairInviteAccepted;

    final completed = await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: ok.responderId,
      responderName: ok.responderName,
      responderPublicKey: ok.responderPublicKey,
      responderEphemeralPublicKey: ok.responderEphemeralPublicKey,
      responderCertFingerprintSha256: ok.responderCertFingerprintSha256,
      observedCertFingerprintSha256: ok.responderCertFingerprintSha256,
      signature: ok.signature,
    );
    expect(completed, isA<PairInviteReady>(),
        reason: 'A should have derived the same PSK from B\'s response');
    await pumpEventQueue();

    await subA.cancel();
    await subB.cancel();

    return (
      aInvite: emittedA.last,
      bInvite: emittedB.last,
      inviteId: payload.inviteId,
    );
  }

  test('handshake derives the same fingerprint on both sides', () async {
    final r = await runHandshake();
    expect(r.aInvite.status, PairInviteStatus.awaitingFingerprint);
    expect(r.bInvite.status, PairInviteStatus.awaitingFingerprint);
    expect(r.aInvite.fingerprint, matches(RegExp(r'^\d{6}$')));
    expect(r.aInvite.fingerprint, equals(r.bInvite.fingerprint));
    expect(r.aInvite.role, PairInviteRole.initiator);
    expect(r.bInvite.role, PairInviteRole.responder);
  });

  test('both Match → pair stored on both sides with the same PSK', () async {
    final r = await runHandshake();

    final aMatch = await a.markLocalMatched(r.inviteId);
    final bMatch = await b.markLocalMatched(r.inviteId);
    expect(aMatch, isNotNull);
    expect(bMatch, isNotNull);

    // Cross-deliver the finalize POSTs.
    final aIntoB = await b.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idA.id,
      verdict: 'match',
      signatureBase64: aMatch!.signatureBase64,
    );
    final bIntoA = await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );
    expect(aIntoB, isA<PairFinalizeRecorded>());
    expect(bIntoA, isA<PairFinalizeRecorded>());

    final storedOnA = (await pairedA.getAll()).single;
    final storedOnB = (await pairedB.getAll()).single;
    expect(storedOnA.deviceId, idB.id);
    expect(storedOnB.deviceId, idA.id);
    // The PSK is symmetric — same 32 bytes on both sides.
    expect(storedOnA.psk, equals(storedOnB.psk));
    // Public keys are pinned so HMAC verification can be tied to identity.
    expect(storedOnA.publicKey, idB.publicKey);
    expect(storedOnB.publicKey, idA.publicKey);
  });

  test('A "Doesn\'t match" → both sides discard, nothing stored', () async {
    final r = await runHandshake();

    final aDecline = await a.markLocalDeclined(r.inviteId);
    expect(aDecline, isNotNull);
    final landed = await b.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idA.id,
      verdict: 'decline',
      signatureBase64: aDecline!.signatureBase64,
    );
    expect(landed, isA<PairFinalizeRecorded>());

    expect(await pairedA.getAll(), isEmpty);
    expect(await pairedB.getAll(), isEmpty);
  });

  test('local Match before remote arrives → waits until remote Match POSTs',
      () async {
    final r = await runHandshake();

    // A matches first; nothing is stored yet because B hasn't replied.
    final aMatch = await a.markLocalMatched(r.inviteId);
    expect(aMatch, isNotNull);
    expect(await pairedA.getAll(), isEmpty);

    // B matches and posts to A. Now A commits.
    final bMatch = await b.markLocalMatched(r.inviteId);
    final intoA = await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );
    expect(intoA, isA<PairFinalizeRecorded>());
    expect((await pairedA.getAll()).single.deviceId, idB.id);
  });

  test('peer routing state survives read-before-flip but is gone after '
      'markLocalMatched commits (audit #35 ordering contract)', () async {
    final r = await runHandshake();
    // Peer matches first so a's markLocalMatched will commit-and-remove in
    // the same call.
    final bMatch = await b.markLocalMatched(r.inviteId);
    await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );
    // Read-before-flip: routing state is present.
    expect(a.peerCertFingerprintFor(r.inviteId), isNotNull,
        reason: 'consumer must read cert fp before markLocalMatched');
    final signed = await a.markLocalMatched(r.inviteId);
    expect(signed, isNotNull);
    // After the commit-and-remove the entry is gone — proving why the
    // controller captures routing into locals first.
    expect(a.peerCertFingerprintFor(r.inviteId), isNull,
        reason: '_maybeCommit removed the pending entry');
    expect(a.peerHostFor(r.inviteId), isNull);
  });

  test('peer signs finalize with the wrong PSK → recordRemoteFinalize '
      'rejects without committing', () async {
    final r = await runHandshake();

    await a.markLocalMatched(r.inviteId);
    final result = await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
    expect(result, isA<PairFinalizeRejected>());
    expect(await pairedA.getAll(), isEmpty);
  });

  test('senderId in finalize must match the in-flight peer', () async {
    final r = await runHandshake();
    final bMatch = await b.markLocalMatched(r.inviteId);
    final result = await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: 'someone-else',
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );
    expect(result, isA<PairFinalizeRejected>());
    expect(await pairedA.getAll(), isEmpty);
  });

  test('imposter cannot pass acceptInvite by claiming idA\'s deviceId '
      'with their own keypair', () async {
    final imposter = await StaticIdentityRepo.create(seed: 99, name: 'Mal');
    // Imposter generates a valid invite of their own, then rewrites it
    // to *claim* idA's id. The Ed25519 sig was made with imposter's
    // key, so the deviceId/publicKey identity check OR the signature
    // check will catch it.
    final invite = await PairInviteService(
      pairedA,
      imposter,
      random: Random(7),
      now: () => now,
    ).createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );

    final result = await b.acceptInvite(
      inviteId: invite.inviteId,
      initiatorId: idA.id, // forged
      initiatorName: 'Lenin-PC',
      initiatorPublicKey: invite.initiatorPublicKey,
      initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: invite.initiatorCertFingerprintSha256,
      nonce: invite.nonce,
      signature: invite.signature,
      expiresAt: invite.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(result, isA<PairInviteRejected>());
  });

  test('expiry purges in-flight state and emits expired status', () async {
    a = PairInviteService(
      pairedA,
      idA,
      random: Random(0),
      now: () => now,
      inviteTtl: const Duration(seconds: 60),
    );
    b = PairInviteService(
      pairedB,
      idB,
      random: Random(1),
      now: () => now,
      inviteTtl: const Duration(seconds: 60),
    );
    final r = await runHandshake();

    final emitted = <PairInvite>[];
    final sub = a.invites.listen(emitted.add);

    now = now.add(const Duration(seconds: 120));
    // Touching state on either service triggers the expiry purge.
    final result = await a.markLocalMatched(r.inviteId);
    expect(result, isNull,
        reason: 'expired in-flight should not produce a finalize body');
    await pumpEventQueue();

    expect(
      emitted.any((e) =>
          e.inviteId == r.inviteId && e.status == PairInviteStatus.expired),
      isTrue,
    );
    expect(await pairedA.getAll(), isEmpty);
    await sub.cancel();
  });

  test('rate limit: a second pending invite from the same source is rejected',
      () async {
    final first = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final firstAccept = await b.acceptInvite(
      inviteId: first.inviteId,
      initiatorId: first.initiatorId,
      initiatorName: first.initiatorName,
      initiatorPublicKey: first.initiatorPublicKey,
      initiatorEphemeralPublicKey: first.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: first.initiatorCertFingerprintSha256,
      nonce: first.nonce,
      signature: first.signature,
      expiresAt: first.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(firstAccept, isA<PairInviteAccepted>());

    final second = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final secondAccept = await b.acceptInvite(
      inviteId: second.inviteId,
      initiatorId: second.initiatorId,
      initiatorName: second.initiatorName,
      initiatorPublicKey: second.initiatorPublicKey,
      initiatorEphemeralPublicKey: second.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: second.initiatorCertFingerprintSha256,
      nonce: second.nonce,
      signature: second.signature,
      expiresAt: second.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(secondAccept, isA<PairInviteRateLimited>());
  });

  test('decline cooldown: after local decline, further invites from the '
      'same source are rate-limited for an hour', () async {
    a = PairInviteService(
      pairedA,
      idA,
      random: Random(0),
      now: () => now,
    );
    b = PairInviteService(
      pairedB,
      idB,
      random: Random(1),
      now: () => now,
      declineCooldown: const Duration(hours: 1),
    );

    // Round 1: A invites, B declines.
    final r = await _runHandshake(a: a, b: b, idA: idA, idB: idB);
    final decline = await b.markLocalDeclined(r.inviteId);
    expect(decline, isNotNull);

    // Round 2: A retries within the cooldown.
    final retry = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final acc = await b.acceptInvite(
      inviteId: retry.inviteId,
      initiatorId: retry.initiatorId,
      initiatorName: retry.initiatorName,
      initiatorPublicKey: retry.initiatorPublicKey,
      initiatorEphemeralPublicKey: retry.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: retry.initiatorCertFingerprintSha256,
      nonce: retry.nonce,
      signature: retry.signature,
      expiresAt: retry.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(acc, isA<PairInviteRateLimited>());

    // Cooldown elapses — accept again.
    now = now.add(const Duration(hours: 1, minutes: 1));
    final retry2 = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final acc2 = await b.acceptInvite(
      inviteId: retry2.inviteId,
      initiatorId: retry2.initiatorId,
      initiatorName: retry2.initiatorName,
      initiatorPublicKey: retry2.initiatorPublicKey,
      initiatorEphemeralPublicKey: retry2.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: retry2.initiatorCertFingerprintSha256,
      nonce: retry2.nonce,
      signature: retry2.signature,
      expiresAt: retry2.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(acc2, isA<PairInviteAccepted>());
  });

  test('decline cooldown entry is purged by the periodic sweep once the '
      'window elapses (audit #32)', () async {
    // Rebuild b sharing the outer `now` (so a's invite isn't already
    // expired) but with a short cooldown + fast sweep we can drive.
    await b.dispose();
    b = PairInviteService(
      pairedB,
      idB,
      random: Random(1),
      now: () => now,
      declineCooldown: const Duration(seconds: 1),
      expirySweepInterval: const Duration(milliseconds: 50),
    );

    // Arm a decline cooldown for idA.
    final r = await _runHandshake(a: a, b: b, idA: idA, idB: idB);
    final decline = await b.markLocalDeclined(r.inviteId);
    expect(decline, isNotNull);
    expect(b.declinedCooldownEntryCount, 1);

    // Advance past the cooldown window and let the periodic sweep tick a
    // few times with NO other call into b.
    now = now.add(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // Pre-fix the sweep never touched _declinedAt, so the entry leaked and
    // the count stayed 1. The audit #32 purge drops it.
    expect(b.declinedCooldownEntryCount, 0,
        reason: 'stale decline-cooldown entry must be purged by the sweep');
  });

  test('responder publicKey/deviceId mismatch in completeInvite is rejected',
      () async {
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final acc = (await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    )) as PairInviteAccepted;

    // Tamper the responderId so it no longer hashes from publicKey.
    final result = await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: 'forged-id',
      responderName: 'imposter',
      responderPublicKey: acc.responderPublicKey,
      responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
      responderCertFingerprintSha256: acc.responderCertFingerprintSha256,
      observedCertFingerprintSha256: acc.responderCertFingerprintSha256,
      signature: acc.signature,
    );
    expect(result, isA<PairInviteCompleteRejected>());
  });

  test('completeInvite rejects when observed TLS cert fingerprint differs '
      'from the signed claim (audit #15 MITM relay)', () async {
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final acc = (await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    )) as PairInviteAccepted;

    // Responder signed _idBCertFp, but the cert actually presented on the
    // wire (observed) was a DIFFERENT fingerprint — the relay-MITM shape.
    final result = await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: acc.responderId,
      responderName: acc.responderName,
      responderPublicKey: acc.responderPublicKey,
      responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
      responderCertFingerprintSha256: acc.responderCertFingerprintSha256,
      observedCertFingerprintSha256: _idACertFp, // != signed claim
      signature: acc.signature,
    );
    expect(result, isA<PairInviteCompleteRejected>());
    expect(await pairedA.getAll(), isEmpty);
  });

  test('completeInvite rejects when no TLS cert was observed (audit #15)',
      () async {
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final acc = (await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    )) as PairInviteAccepted;

    final result = await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: acc.responderId,
      responderName: acc.responderName,
      responderPublicKey: acc.responderPublicKey,
      responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
      responderCertFingerprintSha256: acc.responderCertFingerprintSha256,
      observedCertFingerprintSha256: null,
      signature: acc.signature,
    );
    expect(result, isA<PairInviteCompleteRejected>());
    expect(await pairedA.getAll(), isEmpty);
  });

  test('markLocalMatched emits localMatched on the stream so the modal '
      'can disable the button (slice 5.1.2 regression)', () async {
    final r = await runHandshake();
    final emitted = <PairInvite>[];
    final sub = a.invites.listen(emitted.add);

    // Peer hasn't matched yet — markLocalMatched should not commit but
    // should emit a status event so the UI flips into "waiting".
    await a.markLocalMatched(r.inviteId);
    await pumpEventQueue();

    expect(
      emitted.where((e) =>
          e.inviteId == r.inviteId &&
          e.status == PairInviteStatus.localMatched),
      isNotEmpty,
      reason: 'localMatched status must surface so the modal disables '
          'the Matches button before the peer\'s reciprocal POST arrives',
    );
    await sub.cancel();
  });

  test('markLocalMatched skips localMatched emit when peer already matched '
      '(maybeCommit emits completed instead)', () async {
    final r = await runHandshake();
    // Peer's match arrives first.
    final bMatch = await b.markLocalMatched(r.inviteId);
    await a.recordRemoteFinalize(
      inviteId: r.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );

    final emitted = <PairInvite>[];
    final sub = a.invites.listen(emitted.add);
    await a.markLocalMatched(r.inviteId);
    await pumpEventQueue();

    expect(
      emitted.where(
          (e) => e.status == PairInviteStatus.localMatched),
      isEmpty,
      reason: 'when peerMatched is already true, _maybeCommit emits '
          'completed — no transient localMatched event needed',
    );
    expect(
      emitted.any((e) => e.status == PairInviteStatus.completed),
      isTrue,
    );
    await sub.cancel();
  });

  test('peerHostFor returns the initiator IP captured at acceptInvite '
      '(slice 5.1.2 regression)', () async {
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
      initiatorRemoteHost: '192.168.68.42',
    );

    expect(b.peerHostFor(payload.inviteId), '192.168.68.42');
    expect(a.peerHostFor(payload.inviteId), isNull,
        reason: 'initiator side never captures a remote host — falls back '
            'to peer.host from mDNS');
  });

  test('auto-expire timer fires expired without any other state mutation '
      '(slice 5.1.2 regression — modal would hang forever otherwise)',
      () async {
    // Short TTL + sweep so the test runs in reasonable time. The bug
    // we're guarding against is exactly this: an in-flight invite
    // whose peer never responds, with no other state-mutation call
    // to drag _purgeExpired() along.
    final clock = DateTime.utc(2026, 5, 5, 12);
    var nowFn = clock;
    // Replace the default `b` with one that has a fast sweep, so the
    // canonical signed by `a.createInvite(responderId: idB.id)` still
    // verifies. The default `b` setUp instance is disposed manually
    // here to avoid double-dispose in tearDown.
    await b.dispose();
    b = PairInviteService(
      pairedB,
      idB,
      random: Random(1),
      now: () => nowFn,
      inviteTtl: const Duration(milliseconds: 100),
      expirySweepInterval: const Duration(milliseconds: 50),
    );

    final emitted = <PairInvite>[];
    final sub = b.invites.listen(emitted.add);

    // Mint an invite-in-flight on the responder (b) side without
    // anyone calling markLocalMatched / recordRemoteFinalize. `a` uses
    // the unchanged outer `now`, but the invite carries an `expiresAt`
    // we control, so b's sweep purges it once `nowFn` advances.
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );

    // Advance the clock past the TTL and let the periodic sweep tick.
    nowFn = clock.add(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(
      emitted.any((e) =>
          e.inviteId == payload.inviteId &&
          e.status == PairInviteStatus.expired),
      isTrue,
      reason: 'sweep timer should have purged the in-flight entry',
    );
    await sub.cancel();
  });

  test('replayed /pair-invite (same nonce) is rejected after the pending '
      'entry is gone (audit #14)', () async {
    // Capture the original signed invite body.
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    final accepted = await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(accepted, isA<PairInviteAccepted>());
    final ok = accepted as PairInviteAccepted;

    // Complete on A (so it holds the PSK), then A declines; the decline
    // POST removes B's pending entry WITHOUT arming B's decline cooldown
    // (recordRemoteFinalize 'decline' does not touch _declinedAt), so the
    // re-accept below reaches the replay guard rather than the cooldown.
    await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: ok.responderId,
      responderName: ok.responderName,
      responderPublicKey: ok.responderPublicKey,
      responderEphemeralPublicKey: ok.responderEphemeralPublicKey,
      responderCertFingerprintSha256: ok.responderCertFingerprintSha256,
      observedCertFingerprintSha256: ok.responderCertFingerprintSha256,
      signature: ok.signature,
    );
    final aDecline = await a.markLocalDeclined(payload.inviteId);
    expect(aDecline, isNotNull);
    final landed = await b.recordRemoteFinalize(
      inviteId: payload.inviteId,
      senderId: idA.id,
      verdict: 'decline',
      signatureBase64: aDecline!.signatureBase64,
    );
    expect(landed, isA<PairFinalizeRecorded>());

    // Replay the captured body — same nonce. Pending is gone but the nonce
    // was consumed, so it must be rejected (no new fingerprint modal).
    final replay = await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
      localCertFingerprintSha256: _idBCertFp,
    );
    expect(replay, isA<PairInviteRejected>(),
        reason: 'a consumed invite nonce must not be replayable');
  });

  test('createInvite payload signature verifies under the initiator\'s '
      'long-term key', () async {
    final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
    expect(payload.signature, hasLength(64),
        reason: 'Ed25519 signatures are 64 bytes');
    final canonical = debugInviteCanonical(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      responderId: idB.id,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
      nonce: payload.nonce,
      expiresAt: payload.expiresAt,
    );
    final ok = await LongTermSigner.verify(
      message: canonical,
      signature: payload.signature,
      publicKey: payload.initiatorPublicKey,
    );
    expect(ok, isTrue);
  });
}

/// Helper used by the cooldown test — same shape as the in-test
/// [runHandshake], but parameterised so the local closure can be reused
/// with different services.
Future<({PairInvite aInvite, PairInvite bInvite, String inviteId})>
    _runHandshake({
  required PairInviteService a,
  required PairInviteService b,
  required StaticIdentityRepo idA,
  required StaticIdentityRepo idB,
}) async {
  final emittedA = <PairInvite>[];
  final emittedB = <PairInvite>[];
  final subA = a.invites.listen(emittedA.add);
  final subB = b.invites.listen(emittedB.add);
  final payload = await a.createInvite(
      responderId: idB.id,
      localCertFingerprintSha256: _idACertFp,
    );
  final acc = (await b.acceptInvite(
    inviteId: payload.inviteId,
    initiatorId: payload.initiatorId,
    initiatorName: payload.initiatorName,
    initiatorPublicKey: payload.initiatorPublicKey,
    initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
    initiatorCertFingerprintSha256: payload.initiatorCertFingerprintSha256,
    nonce: payload.nonce,
    signature: payload.signature,
    expiresAt: payload.expiresAt,
    localCertFingerprintSha256: _idBCertFp,
  )) as PairInviteAccepted;
  await a.completeInvite(
    inviteId: payload.inviteId,
    responderId: acc.responderId,
    responderName: acc.responderName,
    responderPublicKey: acc.responderPublicKey,
    responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
    responderCertFingerprintSha256: acc.responderCertFingerprintSha256,
    observedCertFingerprintSha256: acc.responderCertFingerprintSha256,
    signature: acc.signature,
  );
  await pumpEventQueue();
  await subA.cancel();
  await subB.cancel();
  return (
    aInvite: emittedA.last,
    bInvite: emittedB.last,
    inviteId: payload.inviteId,
  );
}

