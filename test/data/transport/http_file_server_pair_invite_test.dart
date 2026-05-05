import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
import 'package:sharer/data/security/pair_invite_service.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/data/transport/transport_protocol.dart';
import 'package:sharer/domain/entities/pair_invite.dart';

import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Boots a real shelf server with the slice 4.6 invite endpoints
/// registered, plus an out-of-process [PairInviteClient] that talks to
/// it over loopback. Confirms the wire format on both ends matches.
void main() {
  late PairedDevicesStore pairedB;
  late StaticIdentityRepo idA;
  late StaticIdentityRepo idB;
  late PairInviteService responderService;
  late PairInviteService initiatorService;
  late PairedDevicesStore pairedA;
  late HttpFileServer server;
  late StreamController<bool> trust;
  late PairInviteClient client;
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sharer_invite_e2e_');
    pairedA = PairedDevicesStore(FakeSecureKeyValueStore());
    pairedB = PairedDevicesStore(FakeSecureKeyValueStore());
    idA = await StaticIdentityRepo.create(seed: 11, name: 'A');
    idB = await StaticIdentityRepo.create(seed: 22, name: 'B');
    initiatorService = PairInviteService(pairedA, idA);
    responderService = PairInviteService(pairedB, idB);
    trust = StreamController<bool>.broadcast();
    server = HttpFileServer(
      downloads: FakeDownloadsLocator(dir),
      isTrusted: trust.stream,
      invite: responderService,
      port: 0,
    );
    await server.start();
    trust.add(true);
    await _settle();
    expect(server.isRunning, isTrue);
    client = PairInviteClient();
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await trust.close();
    await responderService.dispose();
    await initiatorService.dispose();
    await pairedA.dispose();
    await pairedB.dispose();
    dir.deleteSync(recursive: true);
  });

  test('end-to-end invite: A → B over loopback yields matching fingerprints',
      () async {
    final port = server.boundPort!;

    // Subscribe to the responder stream FIRST — broadcast streams
    // don't replay; the awaitingFingerprint event fires synchronously
    // as part of acceptInvite, so a late listener misses it.
    final bInvites = <PairInvite>[];
    final sub = responderService.invites.listen(bInvites.add);

    // A mints + posts invite.
    final payload =
        await initiatorService.createInvite(responderId: idB.id);
    final inviteResult = await client.postInvite(
      host: '127.0.0.1',
      port: port,
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
    );
    expect(inviteResult, isA<PairInvitePostOk>());
    final ok = inviteResult as PairInvitePostOk;

    // A completes locally with B's response.
    final completed = await initiatorService.completeInvite(
      inviteId: payload.inviteId,
      responderId: ok.response.responderId,
      responderName: ok.response.responderName,
      responderPublicKey: ok.response.responderPublicKey,
      responderEphemeralPublicKey: ok.response.responderEphemeralPublicKey,
      signature: ok.response.signature,
    );
    expect(completed, isA<PairInviteReady>());
    final aInvite = (completed as PairInviteReady).invite;

    await pumpEventQueue();
    await sub.cancel();
    expect(bInvites, isNotEmpty);
    final bInvite = bInvites.firstWhere((i) => i.inviteId == payload.inviteId);

    expect(aInvite.fingerprint, equals(bInvite.fingerprint));

    // Both sides match. A's finalize POST commits B's pair entry; B's
    // finalize POST commits A's.
    final aMatch =
        await initiatorService.markLocalMatched(payload.inviteId);
    final bMatch =
        await responderService.markLocalMatched(payload.inviteId);
    expect(aMatch, isNotNull);
    expect(bMatch, isNotNull);

    final aIntoB = await client.postFinalize(
      host: '127.0.0.1',
      port: port,
      inviteId: payload.inviteId,
      senderId: idA.id,
      verdict: 'match',
      signatureBase64: aMatch!.signatureBase64,
    );
    expect(aIntoB, isTrue);

    // B's finalize would normally go over the wire too — feed it
    // straight into A's service to keep this test from needing a
    // second loopback server.
    final bIntoA = await initiatorService.recordRemoteFinalize(
      inviteId: payload.inviteId,
      senderId: idB.id,
      verdict: 'match',
      signatureBase64: bMatch!.signatureBase64,
    );
    expect(bIntoA, isA<PairFinalizeRecorded>());

    final storedOnA = (await pairedA.getAll()).single;
    final storedOnB = (await pairedB.getAll()).single;
    expect(storedOnA.deviceId, idB.id);
    expect(storedOnB.deviceId, idA.id);
    expect(storedOnA.psk, equals(storedOnB.psk));
  });

  test('untrusted network: invite endpoint returns no-route', () async {
    // Bring the server down (untrust).
    trust.add(false);
    await _settle();
    expect(server.isRunning, isFalse);

    // Even raw socket connect fails; the client surfaces a network error.
    final payload =
        await initiatorService.createInvite(responderId: idB.id);
    final result = await client.postInvite(
      host: '127.0.0.1',
      port: 1, // intentionally unreachable port
      inviteId: payload.inviteId,
      initiatorId: payload.initiatorId,
      initiatorName: payload.initiatorName,
      initiatorPublicKey: payload.initiatorPublicKey,
      initiatorEphemeralPublicKey: payload.initiatorEphemeralPublicKey,
      nonce: payload.nonce,
      signature: payload.signature,
      expiresAt: payload.expiresAt,
    );
    expect(result, isA<PairInvitePostNetworkError>());
  });

  test('rate limit: a duplicate /pair-invite with a pending entry returns '
      'HTTP 429', () async {
    final port = server.boundPort!;

    final first =
        await initiatorService.createInvite(responderId: idB.id);
    final firstResult = await client.postInvite(
      host: '127.0.0.1',
      port: port,
      inviteId: first.inviteId,
      initiatorId: first.initiatorId,
      initiatorName: first.initiatorName,
      initiatorPublicKey: first.initiatorPublicKey,
      initiatorEphemeralPublicKey: first.initiatorEphemeralPublicKey,
      nonce: first.nonce,
      signature: first.signature,
      expiresAt: first.expiresAt,
    );
    expect(firstResult, isA<PairInvitePostOk>());

    final second =
        await initiatorService.createInvite(responderId: idB.id);
    final secondResult = await client.postInvite(
      host: '127.0.0.1',
      port: port,
      inviteId: second.inviteId,
      initiatorId: second.initiatorId,
      initiatorName: second.initiatorName,
      initiatorPublicKey: second.initiatorPublicKey,
      initiatorEphemeralPublicKey: second.initiatorEphemeralPublicKey,
      nonce: second.nonce,
      signature: second.signature,
      expiresAt: second.expiresAt,
    );
    expect(secondResult, isA<PairInvitePostDeclined>());
    expect((secondResult as PairInvitePostDeclined).statusCode, 429);
  });

  test('malformed JSON body → 400', () async {
    final port = server.boundPort!;
    final http = HttpClient();
    try {
      final req = await http.postUrl(Uri.parse(
          'http://127.0.0.1:$port${TransportProtocol.pairInvitePath}'));
      final body = utf8.encode('{not valid json');
      req.headers.contentLength = body.length;
      req.headers.contentType = ContentType.json;
      req.add(body);
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.badRequest);
      await resp.drain<void>();
    } finally {
      http.close();
    }
  });

  test('finalize for an unknown invite → 404', () async {
    final port = server.boundPort!;
    final ok = await client.postFinalize(
      host: '127.0.0.1',
      port: port,
      inviteId: 'never-existed',
      senderId: idA.id,
      verdict: 'match',
      signatureBase64:
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
    expect(ok, isFalse);
  });
}
