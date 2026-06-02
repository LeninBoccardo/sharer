import '../entities/peer.dart';

abstract class PeerDiscoveryRepository {
  Stream<List<Peer>> watchPeers();

  /// Reactive view of "are we currently announcing ourselves?". Used by
  /// the diagnostics UI to make the trust gate observable. Emits `true`
  /// when bonsoir's broadcast is live, `false` when it's torn down (quiet
  /// mode) or hasn't started yet.
  Stream<bool> watchAnnouncing();

  /// Re-advertise this device under its current identity name WITHOUT
  /// tearing down discovery. Stops and restarts only the broadcaster
  /// (which re-reads the latest name from the identity repo) while the
  /// observer, peer list, and announcing subscribers stay live. No-op
  /// when not currently announcing (quiet mode / before start). Used by
  /// the rename flow so changing the device name does not cold-start
  /// peer discovery (audit #47).
  Future<void> refreshAnnouncement();

  Future<void> start();

  Future<void> stop();
}
