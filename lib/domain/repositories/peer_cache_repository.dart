import '../entities/peer.dart';

/// Persistent last-known peers. Used to render paired devices instantly on
/// the share screen and to fire optimistic transfers against cached IPs
/// before fresh discovery completes.
abstract class PeerCacheRepository {
  Future<List<Peer>> load();

  Future<void> save(List<Peer> peers);

  Future<void> upsert(Peer peer);

  Future<void> remove(String peerId);

  /// Slice 5.4: persist [host]:[port] for a known [deviceId], minting a
  /// minimal Peer entry if none exists yet. Used by:
  ///
  ///   - HMAC-verified inbound `/upload` and `/pair-finalize` handlers
  ///     (the source IP is by definition reachable, so it's the most
  ///     trustworthy address we'll ever have for that peer);
  ///   - the initiator after a successful `/pair-invite` POST (the host
  ///     it used to reach the responder is known to route);
  ///   - the new `/peer-forgot-you` handler.
  ///
  /// The sender side of any subsequent transfer or pair-finalize prefers
  /// this cached address over bonsoir's resolved `peer.host`, working
  /// around the IP-flake described in
  /// `reference_bonsoir_ip_flake.md`.
  Future<void> cacheAddress({
    required String deviceId,
    required String host,
    required int port,
    String? displayName,
  });

  /// Read-only lookup used by the sender side. Returns null when no
  /// entry exists. The returned [Peer] may be missing fields beyond
  /// host/port (e.g. lastSeen will be the moment the address was
  /// cached, not a real discovery timestamp).
  Future<Peer?> getById(String deviceId);
}
