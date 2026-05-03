import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/discovery/in_memory_peer_discovery.dart';
import '../domain/entities/peer.dart';
import '../domain/repositories/peer_discovery_repository.dart';

/// Composition root: every cross-layer binding is declared here so that
/// presentation code never reaches into `data/` directly. To swap an impl
/// (e.g. real mDNS in Slice 2), override this provider — no UI changes needed.
final peerDiscoveryProvider = Provider<PeerDiscoveryRepository>((ref) {
  final discovery = InMemoryPeerDiscovery();
  ref.onDispose(discovery.dispose);
  discovery.start();
  return discovery;
});

final peersStreamProvider = StreamProvider<List<Peer>>((ref) {
  return ref.watch(peerDiscoveryProvider).watchPeers();
});
