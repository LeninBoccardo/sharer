import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/notifications/notification_coordinator.dart';
import 'package:sharer/data/notifications/notification_service.dart';
import 'package:sharer/domain/entities/pair_invite.dart';
import 'package:sharer/domain/entities/transfer.dart';

/// In-memory recording fake — subclassing the real NotificationService
/// is fine because none of its methods touch the platform plugin
/// unless [init]/[requestPermission] is called, and we never call
/// either here.
class _RecordingService extends NotificationService {
  _RecordingService() : super();

  final List<String> calls = [];

  @override
  Future<void> showTransferActive({
    required String transferId,
    required String peerName,
    required String fileName,
    required int bytesTransferred,
    required int totalBytes,
  }) async {
    calls.add(
        'active:$transferId:$peerName:$fileName:$bytesTransferred/$totalBytes');
  }

  @override
  Future<void> showTransferDone({
    required String transferId,
    required String fileName,
    required String savedPath,
  }) async {
    calls.add('done:$transferId:$fileName:$savedPath');
  }

  @override
  Future<void> showTransferFailed({
    required String transferId,
    required String fileName,
    required String error,
  }) async {
    calls.add('failed:$transferId:$fileName:$error');
  }

  @override
  Future<void> showPairInvite({
    required String inviteId,
    required String peerName,
    required String fingerprint,
  }) async {
    calls.add('invite:$inviteId:$peerName:$fingerprint');
  }

  @override
  Future<void> cancelTransferActive(String transferId) async {
    calls.add('cancelActive:$transferId');
  }

  @override
  Future<void> cancelPairInvite(String inviteId) async {
    calls.add('cancelInvite:$inviteId');
  }
}

Transfer _t({
  required String id,
  required TransferDirection direction,
  required TransferStatus status,
  int bytesTransferred = 0,
  int totalBytes = 1024 * 1024,
  String? errorMessage,
  String? savedPath,
}) =>
    Transfer(
      id: id,
      peerId: 'peer-$id',
      peerName: 'Realme',
      fileName: 'IMG.jpg',
      totalBytes: totalBytes,
      direction: direction,
      startedAt: DateTime(2026, 5, 5, 12, 0),
      status: status,
      bytesTransferred: bytesTransferred,
      errorMessage: errorMessage,
      savedPath: savedPath,
    );

PairInvite _invite({
  required String id,
  required PairInviteRole role,
  required PairInviteStatus status,
}) =>
    PairInvite(
      inviteId: id,
      peerId: 'peer-$id',
      peerName: 'Lenin-PC',
      fingerprint: '123456',
      role: role,
      status: status,
      expiresAt: DateTime(2026, 5, 5, 12, 5),
    );

void main() {
  group('NotificationCoordinator — transfer events', () {
    late _RecordingService service;
    late StreamController<List<Transfer>> transfers;
    late StreamController<PairInvite> invites;
    late StreamController<bool> trusted;
    late NotificationCoordinator coord;

    setUp(() {
      service = _RecordingService();
      transfers = StreamController<List<Transfer>>.broadcast();
      invites = StreamController<PairInvite>.broadcast();
      trusted = StreamController<bool>.broadcast();
      coord = NotificationCoordinator(
        service: service,
        transfers: transfers.stream,
        invites: invites.stream,
        isTrusted: trusted.stream,
      );
      coord.start();
      // Default to trusted; tests that flip it can `trusted.add(false)`.
      trusted.add(true);
    });

    tearDown(() async {
      await coord.dispose();
      await transfers.close();
      await invites.close();
      await trusted.close();
    });

    test('outgoing transfers do not produce any notification', () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.sending,
            status: TransferStatus.inProgress),
      ]);
      await pumpEventQueue();
      expect(service.calls, isEmpty);
    });

    test('first inProgress emission shows transfer-active notification',
        () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress),
      ]);
      await pumpEventQueue();
      expect(service.calls,
          contains(startsWith('active:t1:Realme:IMG.jpg:0/')));
    });

    test('progress updates are throttled to ~256 KB jumps', () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress,
            bytesTransferred: 0),
      ]);
      // Tiny 1KB nudge — should not re-show.
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress,
            bytesTransferred: 1024),
      ]);
      // 300KB jump — exceeds threshold.
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress,
            bytesTransferred: 300 * 1024),
      ]);
      await pumpEventQueue();
      final actives = service.calls.where((c) => c.startsWith('active:t1'));
      expect(actives.length, 2,
          reason: 'first emission + the 300KB jump, not the 1KB nudge');
    });

    test('progress emission at the final byte is always shown', () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress,
            bytesTransferred: 0,
            totalBytes: 50 * 1024),
      ]);
      // Only a 50KB total — without the "always show on final byte"
      // carve-out, the throttle would suppress this update.
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress,
            bytesTransferred: 50 * 1024,
            totalBytes: 50 * 1024),
      ]);
      await pumpEventQueue();
      final actives = service.calls.where((c) => c.startsWith('active:t1'));
      expect(actives.length, 2);
    });

    test('completed transitions cancel-then-done', () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress),
      ]);
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.completed,
            savedPath: '/dl/IMG.jpg'),
      ]);
      await pumpEventQueue();
      // showTransferDone internally cancels the active notification —
      // we don't double-cancel from the coordinator.
      expect(service.calls.last, 'done:t1:IMG.jpg:/dl/IMG.jpg');
    });

    test('failed transitions surface the error', () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress),
      ]);
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.failed,
            errorMessage: 'connection reset'),
      ]);
      await pumpEventQueue();
      expect(service.calls.last, 'failed:t1:IMG.jpg:connection reset');
    });

    test('cancelled transitions just cancel the active notification',
        () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress),
      ]);
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.cancelled),
      ]);
      await pumpEventQueue();
      expect(service.calls.last, 'cancelActive:t1');
    });

    test('repeated emissions in the same terminal state are idempotent',
        () async {
      transfers.add([
        _t(
            id: 't1',
            direction: TransferDirection.receiving,
            status: TransferStatus.inProgress),
      ]);
      final completed = _t(
          id: 't1',
          direction: TransferDirection.receiving,
          status: TransferStatus.completed,
          savedPath: '/dl/IMG.jpg');
      transfers.add([completed]);
      transfers.add([completed]);
      transfers.add([completed]);
      await pumpEventQueue();
      final dones = service.calls.where((c) => c.startsWith('done:t1'));
      expect(dones.length, 1, reason: 'one done call only, no retriggering');
    });
  });

  group('NotificationCoordinator — pair invites', () {
    late _RecordingService service;
    late StreamController<List<Transfer>> transfers;
    late StreamController<PairInvite> invites;
    late StreamController<bool> trusted;
    late NotificationCoordinator coord;

    setUp(() {
      service = _RecordingService();
      transfers = StreamController<List<Transfer>>.broadcast();
      invites = StreamController<PairInvite>.broadcast();
      trusted = StreamController<bool>.broadcast();
      coord = NotificationCoordinator(
        service: service,
        transfers: transfers.stream,
        invites: invites.stream,
        isTrusted: trusted.stream,
      );
      coord.start();
      trusted.add(true);
    });

    tearDown(() async {
      await coord.dispose();
      await transfers.close();
      await invites.close();
      await trusted.close();
    });

    test('responder-side awaitingFingerprint surfaces a notification',
        () async {
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.awaitingFingerprint));
      await pumpEventQueue();
      expect(service.calls, ['invite:i1:Lenin-PC:123456']);
    });

    test('initiator-side invites are NOT surfaced (UI drives that flow)',
        () async {
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.initiator,
          status: PairInviteStatus.awaitingFingerprint));
      await pumpEventQueue();
      expect(service.calls, isEmpty);
    });

    test('terminal status cancels the invite notification', () async {
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.awaitingFingerprint));
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.completed));
      await pumpEventQueue();
      expect(service.calls.last, 'cancelInvite:i1');
    });

    test('invite notification is shown only once per id', () async {
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.awaitingFingerprint));
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.awaitingFingerprint));
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.localMatched));
      await pumpEventQueue();
      final invitesShown = service.calls.where((c) => c.startsWith('invite:'));
      expect(invitesShown.length, 1);
    });

    test('invites on untrusted networks are dropped', () async {
      // Defensive — slice 4.6 keeps /pair-invite trust-gated, so this
      // path shouldn't fire in production. But the coordinator still
      // guards against a stale emission.
      trusted.add(false);
      await pumpEventQueue();
      invites.add(_invite(
          id: 'i1',
          role: PairInviteRole.responder,
          status: PairInviteStatus.awaitingFingerprint));
      await pumpEventQueue();
      expect(service.calls, isEmpty);
    });
  });
}
