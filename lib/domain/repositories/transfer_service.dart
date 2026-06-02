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
  ///
  /// [reopen], when supplied, is a factory that re-opens the source as a
  /// fresh byte stream (e.g. `() => File(path).openRead()`). The first
  /// upload still consumes [file]; the factory is retained so a later
  /// [retry] can re-stream from zero without buffering. When [reopen] is
  /// null the resulting transfer is not retryable ([Transfer.canRetry] is
  /// false).
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  });

  /// Aborts an in-flight outgoing transfer identified by [transferId].
  ///
  /// The transfer transitions to [TransferStatus.cancelled] and the
  /// underlying upload stream/connection is torn down. Idempotent: a
  /// no-op when [transferId] is unknown, already terminal, or refers to
  /// an incoming (receive-direction) transfer. The resulting status is
  /// observed via [watchAll]; the future completes once the cancel has
  /// been signalled (not necessarily once the socket has fully closed).
  Future<void> cancel(String transferId);

  /// Re-runs a previously-failed outgoing transfer from zero, reusing the
  /// same [transferId] (so the UI tile/screen updates in place rather than
  /// spawning a new row). Idempotent no-op when [transferId] is unknown,
  /// not in [TransferStatus.failed], incoming (receive-direction), or has
  /// no retained re-open source (i.e. [send] was called without `reopen`).
  /// v1 retries from the start — NOT a resume. Progress is observed via
  /// [watchAll].
  Future<void> retry(String transferId);
}
