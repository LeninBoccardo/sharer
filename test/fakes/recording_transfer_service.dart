import 'dart:async';

import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';

/// A [TransferService] fake that RECORDS every [send] (peer id + file name)
/// and returns a synthetic terminal [Transfer] with a unique id. Used by the
/// multi-peer fan-out test to assert which peers a send was dispatched to.
///
/// Unlike [FakeTransferService] (which throws on send and is for static
/// layout tests), this one is send-capable: [watchAll] replays the recorded
/// transfers (seeded for late subscribers, then live) so both the
/// coordinator's drain-gate and the pushed [TransferScreen] resolve and the
/// test can [pumpAndSettle] without an infinite spinner. Transfers are minted
/// in [TransferStatus.completed] so the drain-gate terminates immediately and
/// no progress/rate animation keeps the frame loop busy.
class RecordingTransferService implements TransferService {
  RecordingTransferService();

  /// One entry per [send] call, in call order.
  final List<({String peerId, String fileName})> sends = [];

  final List<Transfer> _transfers = [];
  final _controller = StreamController<List<Transfer>>.broadcast();
  int _seq = 0;

  /// The set of distinct peer ids a file was dispatched to.
  Set<String> get sentPeerIds => {for (final s in sends) s.peerId};

  @override
  Stream<List<Transfer>> watchAll() async* {
    yield List.unmodifiable(_transfers);
    yield* _controller.stream;
  }

  @override
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  }) async {
    final transfer = Transfer(
      id: 'tx-${_seq++}',
      peerId: peer.id,
      peerName: peer.name,
      fileName: file.fileName,
      totalBytes: file.sizeBytes,
      direction: TransferDirection.sending,
      startedAt: DateTime.utc(2026, 6, 2),
      status: TransferStatus.completed,
      completedAt: DateTime.utc(2026, 6, 2),
    );
    sends.add((peerId: peer.id, fileName: file.fileName));
    _transfers.add(transfer);
    _controller.add(List.unmodifiable(_transfers));
    return transfer;
  }

  @override
  Future<void> cancel(String transferId) async {}

  @override
  Future<void> retry(String transferId) async {}

  Future<void> dispose() => _controller.close();
}
