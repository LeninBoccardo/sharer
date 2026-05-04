import '../entities/peer.dart';

abstract class PeerDiscoveryRepository {
  Stream<List<Peer>> watchPeers();

  /// Reactive view of "are we currently announcing ourselves?". Used by
  /// the diagnostics UI to make the trust gate observable. Emits `true`
  /// when bonsoir's broadcast is live, `false` when it's torn down (quiet
  /// mode) or hasn't started yet.
  Stream<bool> watchAnnouncing();

  Future<void> start();

  Future<void> stop();
}
