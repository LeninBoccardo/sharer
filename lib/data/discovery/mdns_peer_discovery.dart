import 'dart:async';
import 'dart:developer' as developer;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

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
  static const _logName = 'sharer.discovery';

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
  final _announcingController = StreamController<bool>.broadcast();
  List<Peer> _latest = const [];
  bool _announcing = false;
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
  Stream<bool> watchAnnouncing() async* {
    yield _announcing;
    yield* _announcingController.stream;
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _log('Starting discovery for $serviceType');
    _discovery = BonsoirDiscovery(type: serviceType);
    await _discovery!.ready;
    // CRITICAL: subscribe BEFORE start(). bonsoir's eventStream is a
    // broadcast stream from EventChannel.receiveBroadcastStream(), which
    // does NOT buffer — events emitted by the platform between start()
    // returning and listen() attaching are dropped. On a fast Android
    // device, "found" + "resolved" for already-on-the-network peers can
    // fire in that window, leaving the UI permanently empty.
    _discoverySub = _discovery!.eventStream?.listen(_onDiscoveryEvent);
    await _discovery!.start();

    _announceSub = _shouldAnnounce.listen(_onAnnounceFlag);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    _log('Stopping discovery + broadcast');
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
    await _announcingController.close();
  }

  Future<void> _onAnnounceFlag(bool announce) async {
    _log('Announce flag → $announce');
    if (announce) {
      await _startBroadcast();
    } else {
      await _stopBroadcast();
    }
  }

  Future<void> _startBroadcast() async {
    if (_broadcast != null) return;
    final identity = await _identityRepo.get();
    _log('Starting broadcast: name="${identity.name}" id=${identity.id} port=$advertisedPort');
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
    _setAnnouncing(true);
  }

  Future<void> _stopBroadcast() async {
    final b = _broadcast;
    if (b == null) return;
    _broadcast = null;
    _log('Stopping broadcast');
    await b.stop();
    _setAnnouncing(false);
  }

  void _setAnnouncing(bool value) {
    if (_announcing == value) return;
    _announcing = value;
    _announcingController.add(value);
  }

  /// Logs to BOTH `developer.log` (DevTools-friendly, structured) and
  /// `debugPrint` (terminal-friendly, visible in `flutter run` and
  /// `adb logcat`). Real-device debugging needs the latter.
  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }

  Future<void> _onDiscoveryEvent(BonsoirDiscoveryEvent event) async {
    final svc = event.service;
    final svcDesc = svc == null
        ? '(no service)'
        : 'name="${svc.name}" id=${svc.attributes[_kDeviceIdAttr] ?? "(none)"}';
    _log('Event ${event.type.name} → $svcDesc');

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
          if (id != null && _peers.remove(id) != null) {
            _log('Removed peer $id; peers=${_peers.length}');
            _emit();
          }
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
    if (id == null) {
      _log('Resolved without deviceId — skipping (name="${svc.name}")');
      return;
    }
    if (id == identity.id) {
      _log('Resolved self — skipping (name="${svc.name}")');
      return;
    }

    _peers[id] = Peer(
      id: id,
      name: svc.name,
      host: svc.host,
      port: svc.port,
      // Pairing arrives in slice 4; until then everyone shows as unpaired.
      isPaired: false,
      lastSeen: DateTime.now(),
    );
    _log('Added peer name="${svc.name}" id=$id host=${svc.host}:${svc.port}; peers=${_peers.length}');
    _emit();
  }

  void _emit() {
    _latest = _peers.values.toList(growable: false);
    _peersController.add(_latest);
  }
}
