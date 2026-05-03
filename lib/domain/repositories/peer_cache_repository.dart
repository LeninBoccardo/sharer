import '../entities/peer.dart';

/// Persistent last-known peers. Used to render paired devices instantly on
/// the share screen and to fire optimistic transfers against cached IPs
/// before fresh discovery completes.
abstract class PeerCacheRepository {
  Future<List<Peer>> load();

  Future<void> save(List<Peer> peers);

  Future<void> upsert(Peer peer);

  Future<void> remove(String peerId);
}
