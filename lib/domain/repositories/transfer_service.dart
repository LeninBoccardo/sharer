import '../entities/file_payload.dart';
import '../entities/peer.dart';
import '../entities/transfer.dart';

/// Coordinates outgoing sends and incoming receives. UI consumes
/// [watchAll] to render in-flight + recent transfers.
abstract class TransferService {
  /// Snapshot stream of all known transfers (sending + receiving), most
  /// recent first.
  Stream<List<Transfer>> watchAll();

  /// Begins sending [file] to [peer]. Returns the [Transfer] in its
  /// initial pending state immediately; progress + completion are
  /// observed via [watchAll].
  Future<Transfer> send({required Peer peer, required FilePayload file});

  /// Aborts an in-flight outgoing transfer identified by [transferId].
  ///
  /// The transfer transitions to [TransferStatus.cancelled] and the
  /// underlying upload stream/connection is torn down. Idempotent: a
  /// no-op when [transferId] is unknown, already terminal, or refers to
  /// an incoming (receive-direction) transfer. The resulting status is
  /// observed via [watchAll]; the future completes once the cancel has
  /// been signalled (not necessarily once the socket has fully closed).
  Future<void> cancel(String transferId);
}
