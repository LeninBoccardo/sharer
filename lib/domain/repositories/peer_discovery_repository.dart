import '../entities/peer.dart';

abstract class PeerDiscoveryRepository {
  Stream<List<Peer>> watchPeers();

  Future<void> start();

  Future<void> stop();
}
