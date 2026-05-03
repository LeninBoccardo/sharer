import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/peer_discovery_repository.dart';

/// Discovery + announcement over mDNS / DNS-SD using bonsoir.
///
/// Discovery (listen) runs whenever [start] has been called — even on
/// untrusted networks, so paired peers that announce themselves there are
/// still found.
///
/// Announcement is gated by [shouldAnnounce]: when it emits `true` we
/// publish ourselves under `_sharer._tcp`; when `false` (quiet mode on an
/// unrecognized network), we tear the broadcast down. See
/// docs/v1/security.md for the rationale.
class MdnsPeerDiscovery implements PeerDiscoveryRepository {
  static const serviceType = '_sharer._tcp';
  static const _kDeviceIdAttr = 'deviceId';

  /// Port we will eventually run the HTTP server on. Slice 3 will start the
  /// server here; until then this is the advertised endpoint only.
  static const advertisedPort = 8080;

  final DeviceIdentityRepository _identityRepo;
  final Stream<bool> _shouldAnnounce;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  StreamSubscription<bool>? _announceSub;

  final Map<String, Peer> _peers = {};
  final _peersController = StreamController<List<Peer>>.broadcast();
  List<Peer> _latest = const [];
  bool _started = false;

  MdnsPeerDiscovery({
    required DeviceIdentityRepository identityRepo,
    required Stream<bool> shouldAnnounce,
  })  : _identityRepo = identityRepo,
        _shouldAnnounce = shouldAnnounce;

  @override
  Stream<List<Peer>> watchPeers() async* {
    yield _latest;
    yield* _peersController.stream;
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _discovery = BonsoirDiscovery(type: serviceType);
    await _discovery!.ready;
    await _discovery!.start();
    _discoverySub = _discovery!.eventStream?.listen(_onDiscoveryEvent);

    _announceSub = _shouldAnnounce.listen(_onAnnounceFlag);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    await _announceSub?.cancel();
    _announceSub = null;
    await _stopBroadcast();

    await _discoverySub?.cancel();
    _discoverySub = null;
    await _discovery?.stop();
    _discovery = null;

    _peers.clear();
    _emit();
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
  }

  Future<void> _onAnnounceFlag(bool announce) async {
    if (announce) {
      await _startBroadcast();
    } else {
      await _stopBroadcast();
    }
  }

  Future<void> _startBroadcast() async {
    if (_broadcast != null) return;
    final identity = await _identityRepo.get();
    final service = BonsoirService(
      name: identity.name,
      type: serviceType,
      port: advertisedPort,
      attributes: {_kDeviceIdAttr: identity.id},
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.ready;
    await broadcast.start();
    _broadcast = broadcast;
  }

  Future<void> _stopBroadcast() async {
    final b = _broadcast;
    if (b == null) return;
    _broadcast = null;
    await b.stop();
  }

  Future<void> _onDiscoveryEvent(BonsoirDiscoveryEvent event) async {
    final svc = event.service;
    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        if (svc != null) {
          // Resolution is async; the resolved event arrives later with host.
          await svc.resolve(_discovery!.serviceResolver);
        }
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        if (svc is ResolvedBonsoirService) {
          await _onResolved(svc);
        }
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        if (svc != null) {
          final id = svc.attributes[_kDeviceIdAttr];
          if (id != null && _peers.remove(id) != null) _emit();
        }
      case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
      case BonsoirDiscoveryEventType.discoveryStarted:
      case BonsoirDiscoveryEventType.discoveryStopped:
      case BonsoirDiscoveryEventType.unknown:
        break;
    }
  }

  Future<void> _onResolved(ResolvedBonsoirService svc) async {
    final identity = await _identityRepo.get();
    final id = svc.attributes[_kDeviceIdAttr];
    if (id == null || id == identity.id) return; // skip self & ID-less peers

    _peers[id] = Peer(
      id: id,
      name: svc.name,
      host: svc.host,
      port: svc.port,
      // Pairing arrives in slice 4; until then everyone shows as unpaired.
      isPaired: false,
      lastSeen: DateTime.now(),
    );
    _emit();
  }

  void _emit() {
    _latest = _peers.values.toList(growable: false);
    _peersController.add(_latest);
  }
}
