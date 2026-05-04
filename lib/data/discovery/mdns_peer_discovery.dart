import 'dart:async';
import 'dart:developer' as developer;

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/peer_discovery_repository.dart';

/// Discovery + announcement over mDNS / DNS-SD using bonsoir.
///
/// Both discovery and announcement are gated by [isTrusted]: when it emits
/// `true` we publish ourselves AND start listening for `_sharer._tcp`
/// peers; when `false` (untrusted network), we tear both down and clear
/// the peer list. See docs/v1/security.md.
///
/// Future (slice 4 — pairing): on untrusted networks we'll keep a thin
/// listener active so paired peers can still be discovered, but filter
/// out unpaired services. Until pairing exists, full silence is the
/// correct behavior — an "always-on listener" leaks discovery to any
/// network the device joins.
class MdnsPeerDiscovery implements PeerDiscoveryRepository {
  static const serviceType = '_sharer._tcp';
  static const _kDeviceIdAttr = 'deviceId';
  static const _logName = 'sharer.discovery';

  /// Port we will eventually run the HTTP server on. Slice 3 will start the
  /// server here; until then this is the advertised endpoint only.
  static const advertisedPort = 8080;

  final DeviceIdentityRepository _identityRepo;
  final Stream<bool> _isTrusted;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  StreamSubscription<bool>? _trustSub;

  final Map<String, Peer> _peers = {};
  final _peersController = StreamController<List<Peer>>.broadcast();
  final _announcingController = StreamController<bool>.broadcast();
  List<Peer> _latest = const [];
  bool _announcing = false;
  bool _started = false;

  MdnsPeerDiscovery({
    required DeviceIdentityRepository identityRepo,
    required Stream<bool> isTrusted,
  })  : _identityRepo = identityRepo,
        _isTrusted = isTrusted;

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
    _log('Started — reacting to trust state');
    _trustSub = _isTrusted.listen(_onTrustChange);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _log('Stopping');
    await _trustSub?.cancel();
    _trustSub = null;
    await _disable();
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
    await _announcingController.close();
  }

  Future<void> _onTrustChange(bool trusted) async {
    _log('Trust → $trusted');
    if (trusted) {
      await _enable();
    } else {
      await _disable();
    }
  }

  Future<void> _enable() async {
    if (_discovery != null) return; // already enabled
    await _startDiscovery();
    await _startBroadcast();
  }

  Future<void> _disable() async {
    await _stopDiscovery();
    await _stopBroadcast();
    if (_peers.isNotEmpty) {
      _peers.clear();
      _log('Cleared peer list (untrusted network)');
      _emit();
    }
  }

  Future<void> _startDiscovery() async {
    _log('Starting discovery for $serviceType');
    final discovery = BonsoirDiscovery(type: serviceType);
    await discovery.ready;
    // CRITICAL: subscribe BEFORE start(). bonsoir's eventStream is a
    // broadcast stream from EventChannel.receiveBroadcastStream(), which
    // does NOT buffer — events emitted by the platform between start()
    // returning and listen() attaching are dropped.
    _discoverySub = discovery.eventStream?.listen(_onDiscoveryEvent);
    await discovery.start();
    _discovery = discovery;
  }

  Future<void> _stopDiscovery() async {
    final d = _discovery;
    if (d == null) return;
    _discovery = null;
    _log('Stopping discovery');
    await _discoverySub?.cancel();
    _discoverySub = null;
    await d.stop();
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
