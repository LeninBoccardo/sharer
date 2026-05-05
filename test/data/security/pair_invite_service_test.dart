import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/long_term_signer.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pair_invite_service.dart';
import 'package:sharer/domain/entities/pair_invite.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

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

    final payload = await a.createInvite(responderId: idB.id);
    final accepted = await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
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
    ).createInvite(responderId: idB.id);

    final result = await b.acceptInvite(
      inviteId: invite.inviteId,
      initiatorId: idA.id, // forged
      initiatorName: 'Lenin-PC',
      initiatorPublicKey: invite.initiatorPublicKey,
      initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
      nonce: invite.nonce,
      signature: invite.signature,
      expiresAt: invite.expiresAt,
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
    final first = await a.createInvite(responderId: idB.id);
    final firstAccept = await b.acceptInvite(
      inviteId: first.inviteId,
      initiatorId: first.initiatorId,
      initiatorName: first.initiatorName,
      initiatorPublicKey: first.initiatorPublicKey,
      initiatorEphemeralPublicKey: first.initiatorEphemeralPublicKey,
      nonce: first.nonce,
      signature: first.signature,
      expiresAt: first.expiresAt,
    );
    expect(firstAccept, isA<PairInviteAccepted>());

    final second = await a.createInvite(responderId: idB.id);
    final secondAccept = await b.acceptInvite(
      inviteId: second.inviteId,
      initiatorId: second.initiatorId,
      initiatorName: second.initiatorName,
      initiatorPublicKey: second.initiatorPublicKey,
      initiatorEphemeralPublicKey: second.initiatorEphemeralPublicKey,
      nonce: second.nonce,
      signature: second.signature,
      expiresAt: second.expiresAt,
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
    final retry = await a.createInvite(responderId: idB.id);
    final acc = await b.acceptInvite(
      inviteId: retry.inviteId,
      initiatorId: retry.initiatorId,
      initiatorName: retry.initiatorName,
      initiatorPublicKey: retry.initiatorPublicKey,
      initiatorEphemeralPublicKey: retry.initiatorEphemeralPublicKey,
      nonce: retry.nonce,
      signature: retry.signature,
      expiresAt: retry.expiresAt,
    );
    expect(acc, isA<PairInviteRateLimited>());

    // Cooldown elapses — accept again.
    now = now.add(const Duration(hours: 1, minutes: 1));
    final retry2 = await a.createInvite(responderId: idB.id);
    final acc2 = await b.acceptInvite(
      inviteId: retry2.inviteId,
      initiatorId: retry2.initiatorId,
      initiatorName: retry2.initiatorName,
      initiatorPublicKey: retry2.initiatorPublicKey,
      initiatorEphemeralPublicKey: retry2.initiatorEphemeralPublicKey,
      nonce: retry2.nonce,
      signature: retry2.signature,
      expiresAt: retry2.expiresAt,
    );
    expect(acc2, isA<PairInviteAccepted>());
  });

  test('responder publicKey/deviceId mismatch in completeInvite is rejected',
      () async {
    final payload = await a.createInvite(responderId: idB.id);
    final acc = (await b.acceptInvite(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
    )) as PairInviteAccepted;

    // Tamper the responderId so it no longer hashes from publicKey.
    final result = await a.completeInvite(
      inviteId: payload.inviteId,
      responderId: 'forged-id',
      responderName: 'imposter',
      responderPublicKey: acc.responderPublicKey,
      responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
      signature: acc.signature,
    );
    expect(result, isA<PairInviteCompleteRejected>());
  });

  test('createInvite payload signature verifies under the initiator\'s '
      'long-term key', () async {
    final payload = await a.createInvite(responderId: idB.id);
    expect(payload.signature, hasLength(64),
        reason: 'Ed25519 signatures are 64 bytes');
    final canonical = debugInviteCanonical(
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      responderId: idB.id,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
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
  final payload = await a.createInvite(responderId: idB.id);
  final acc = (await b.acceptInvite(
    inviteId: payload.inviteId,
    initiatorId: payload.initiatorId,
    initiatorName: payload.initiatorName,
    initiatorPublicKey: payload.initiatorPublicKey,
    initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
    nonce: payload.nonce,
    signature: payload.signature,
    expiresAt: payload.expiresAt,
  )) as PairInviteAccepted;
  await a.completeInvite(
    inviteId: payload.inviteId,
    responderId: acc.responderId,
    responderName: acc.responderName,
    responderPublicKey: acc.responderPublicKey,
    responderEphemeralPublicKey: acc.responderEphemeralPublicKey,
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

