import 'dart:async';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/peer_discovery_repository.dart';

/// Placeholder discovery impl used until the real mDNS adapter lands in Slice 2.
/// Emits an empty peer list once started; lets the rest of the architecture
/// (providers, UI) be wired and tested without depending on multicast sockets.
class InMemoryPeerDiscovery implements PeerDiscoveryRepository {
  final _controller = StreamController<List<Peer>>.broadcast();
  List<Peer> _latest = const [];
  bool _started = false;

  /// Seeds late subscribers with the latest known peer list so they don't
  /// have to wait for the next [_emit] to render.
  @override
  Stream<List<Peer>> watchPeers() async* {
    yield _latest;
    yield* _controller.stream;
  }

  @override
  Stream<bool> watchAnnouncing() => Stream<bool>.value(false);

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _emit(const []);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _emit(const []);
  }

  void _emit(List<Peer> peers) {
    _latest = peers;
    _controller.add(peers);
  }

  Future<void> dispose() => _controller.close();
}
