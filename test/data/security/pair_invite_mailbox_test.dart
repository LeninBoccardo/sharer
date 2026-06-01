import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/in_flight_invite_store.dart';
import 'package:sharer/data/security/pair_invite_service.dart';
import 'package:sharer/data/security/paired_devices_store.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

const _idACertFp = 'aa:11:bb:22:cc:33:dd:44:ee:55:ff:66:'
    '00:77:11:88:22:99:33:aa:44:bb:55:cc:'
    '66:dd:77:ee:88:ff:99:00';
const _idBCertFp = '11:aa:22:bb:33:cc:44:dd:55:ee:66:ff:'
    '77:00:88:11:99:22:aa:33:bb:44:cc:55:'
    'dd:66:ee:77:ff:88:00:99';

/// Slice 5.2.4.2 — verifies that the responder side persists a
/// pre-signed decline payload to InFlightInviteStore on acceptInvite,
/// and clears it on every lifecycle exit (commit / local decline /
/// remote decline / expiry / abandon).
void main() {
  late FakeSecureKeyValueStore secureA;
  late FakeSecureKeyValueStore secureB;
  late PairedDevicesStore pairedA;
  late PairedDevicesStore pairedB;
  late StaticIdentityRepo idA;
  late StaticIdentityRepo idB;
  late InFlightInviteStore mailbox;
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
    mailbox = InFlightInviteStore(secureB);
    now = DateTime.utc(2026, 5, 6, 12);
    a = PairInviteService(
      pairedA,
      idA,
      random: Random(0),
      now: () => now,
    );
    b = PairInviteService(
      pairedB,
      idB,
      mailbox: mailbox, // responder-side mailbox under test
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

  Future<({String inviteId, PairInviteAccepted accepted})> acceptOnB({
    String? remoteHost,
  }) async {
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
      initiatorRemoteHost: remoteHost ?? '192.168.68.57',
    );
    expect(accepted, isA<PairInviteAccepted>());
    return (inviteId: payload.inviteId, accepted: accepted as PairInviteAccepted);
  }

  /// Runs the FULL invite/response cycle so both A and B have an
  /// in-flight pending entry and can call markLocalMatched /
  /// markLocalDeclined. Required by tests that exercise the mutual-
  /// match commit path or A-side decline.
  Future<String> runHandshake() async {
    final r = await acceptOnB();
    final completed = await a.completeInvite(
      inviteId: r.inviteId,
      responderId: r.accepted.responderId,
      responderName: r.accepted.responderName,
      responderPublicKey: r.accepted.responderPublicKey,
      responderEphemeralPublicKey: r.accepted.responderEphemeralPublicKey,
      responderCertFingerprintSha256:
          r.accepted.responderCertFingerprintSha256,
      observedCertFingerprintSha256:
          r.accepted.responderCertFingerprintSha256,
      signature: r.accepted.signature,
    );
    expect(completed, isA<PairInviteReady>());
    return r.inviteId;
  }

  test('acceptInvite persists the mailbox entry with peer routing + '
      'pre-signed decline', () async {
    final r = await acceptOnB();
    final entry = await mailbox.get(r.inviteId);
    expect(entry, isNotNull);
    expect(entry!.inviteId, r.inviteId);
    expect(entry.peerId, idA.id);
    expect(entry.peerHost, '192.168.68.57');
    expect(entry.peerPort, 8080);
    expect(entry.peerCertFingerprint, _idACertFp);
    expect(entry.senderId, idB.id);
    expect(entry.declineSignatureBase64, isNotEmpty);
  });

  test('acceptInvite without an initiatorRemoteHost does not write a '
      'mailbox entry (BG decline cannot route without a host)', () async {
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
      // initiatorRemoteHost: null,
    );
    expect(accepted, isA<PairInviteAccepted>());
    expect(await mailbox.get(payload.inviteId), isNull);
  });

  test('local decline clears the mailbox entry', () async {
    final r = await acceptOnB();
    expect(await mailbox.get(r.inviteId), isNotNull);
    await b.markLocalDeclined(r.inviteId);
    expect(await mailbox.get(r.inviteId), isNull);
  });

  test('remote decline (peer hit Doesn\'t match) clears the mailbox', () async {
    final inviteId = await runHandshake();
    // A declines.
    final aDecline = await a.markLocalDeclined(inviteId);
    expect(aDecline, isNotNull);
    final landed = await b.recordRemoteFinalize(
      inviteId: inviteId,
      senderId: idA.id,
      verdict: 'decline',
      signatureBase64: aDecline!.signatureBase64,
    );
    expect(landed, isA<PairFinalizeRecorded>());
    expect(await mailbox.get(inviteId), isNull);
  });

  test('committed pair clears the mailbox', () async {
    final inviteId = await runHandshake();
    final aMatch = await a.markLocalMatched(inviteId);
    final bMatch = await b.markLocalMatched(inviteId);
    expect(aMatch, isNotNull);
    expect(bMatch, isNotNull);
    await b.recordRemoteFinalize(
      inviteId: inviteId,
      senderId: idA.id,
      verdict: 'match',
      signatureBase64: aMatch!.signatureBase64,
    );
    expect(await mailbox.get(inviteId), isNull);
  });

  test('expired invite clears the mailbox via _purgeExpired sweep',
      () async {
    final r = await acceptOnB();
    expect(await mailbox.get(r.inviteId), isNotNull);

    // Advance time past TTL (default 5 min) so the next mutating call
    // triggers _purgeExpired which calls mailbox.purgeExpired().
    now = now.add(const Duration(minutes: 6));
    // Trigger via a no-op-ish call that runs _purgeExpired.
    await b.markLocalMatched('non-existent-id');

    // Pump for the unawaited mailbox.purgeExpired to settle.
    await pumpEventQueue();
    expect(await mailbox.get(r.inviteId), isNull);
  });
}
