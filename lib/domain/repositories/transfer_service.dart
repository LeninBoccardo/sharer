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
}
