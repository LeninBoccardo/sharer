import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/peer_discovery_repository.dart';
import 'mdns_backend.dart';

/// Trust-gated peer discovery + announcement orchestration.
///
/// ## Strong rules
///
/// 1. **Discovery and broadcast are atomic with trust state.** When the
///    network is trusted both run; when it's not, neither runs. There is
///    no in-between state.
/// 2. **Trust transitions are serialized.** Concurrent calls into
///    [_onTrustChange] cannot overlap. The latest desired state always
///    wins; intermediate states converge.
/// 3. **Peer list is cleared on untrust.** A peer that was visible on a
///    trusted network must not linger after the user untrusts. Stale
///    state is a security smell.
/// 4. **Self is filtered by deviceId, not by service name.** The bonsoir
///    NSD layer can auto-rename services on collision (the "(2)" suffix
///    you saw); deviceId is stable.
/// 5. **Service names are session-unique.** A new random suffix every
///    broadcast prevents NSD from renaming on local cache collisions.
///    The human-readable name lives in the `name` TXT attribute.
/// 6. **Subscribe before start.** Enforced inside [BonsoirMdnsBackend] —
///    bonsoir's broadcast event stream drops anything emitted before
///    listen attaches.
class MdnsPeerDiscovery implements PeerDiscoveryRepository {
  static const serviceType = '_sharer._tcp';
  static const _kDeviceIdAttr = 'deviceId';
  static const _kNameAttr = 'name';
  static const _logName = 'sharer.discovery';

  /// Port we will eventually run the HTTP server on. Slice 3 will start the
  /// server here; until then this is the advertised endpoint only.
  static const advertisedPort = 8080;

  final MdnsBackend _backend;
  final DeviceIdentityRepository _identityRepo;
  final Stream<bool> _isTrusted;
  final Random _random;

  MdnsBroadcaster? _broadcaster;
  MdnsObserver? _observer;
  StreamSubscription<bool>? _trustSub;
  StreamSubscription<MdnsEvent>? _eventsSub;

  final Map<String, Peer> _peers = {};
  final _peersController = StreamController<List<Peer>>.broadcast();
  final _announcingController = StreamController<bool>.broadcast();
  List<Peer> _latest = const [];
  bool _announcing = false;
  bool _started = false;

  // Reconciler state.
  bool _desiredEnabled = false;
  bool _reconcileInFlight = false;
  bool _reconcileQueued = false;

  MdnsPeerDiscovery({
    required MdnsBackend backend,
    required DeviceIdentityRepository identityRepo,
    required Stream<bool> isTrusted,
    Random? random,
  })  : _backend = backend,
        _identityRepo = identityRepo,
        _isTrusted = isTrusted,
        _random = random ?? Random();

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
    _desiredEnabled = false;
    await _runReconcileToCompletion();
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
    await _announcingController.close();
  }

  // -------- Reconciler --------

  void _onTrustChange(bool trusted) {
    _log('Trust → $trusted');
    _desiredEnabled = trusted;
    _scheduleReconcile();
  }

  void _scheduleReconcile() {
    if (_reconcileInFlight) {
      // A reconcile is already running. Just bump the flag — it'll see
      // the latest [_desiredEnabled] on its next iteration.
      _reconcileQueued = true;
      return;
    }
    unawaited(_runReconcileToCompletion());
  }

  Future<void> _runReconcileToCompletion() async {
    if (_reconcileInFlight) {
      // Wait for the in-flight reconciler to finish (it'll pick up our
      // changes via the queued flag).
      _reconcileQueued = true;
      while (_reconcileInFlight) {
        await Future<void>.delayed(Duration.zero);
      }
      return;
    }
    _reconcileInFlight = true;
    try {
      do {
        _reconcileQueued = false;
        await _applyDesiredState();
      } while (_reconcileQueued);
    } finally {
      _reconcileInFlight = false;
    }
  }

  Future<void> _applyDesiredState() async {
    final shouldBeEnabled = _desiredEnabled && _started;
    final isEnabled = _broadcaster != null || _observer != null;
    if (shouldBeEnabled == isEnabled) return;
    if (shouldBeEnabled) {
      await _enable();
    } else {
      await _disable();
    }
  }

  Future<void> _enable() async {
    try {
      await _startObserver();
      await _startBroadcaster();
    } catch (e, st) {
      _log('Enable failed: $e');
      developer.log('Enable failed', error: e, stackTrace: st, name: _logName);
      // Roll back to a clean state so the next reconcile can retry.
      await _disable();
      rethrow;
    }
  }

  Future<void> _disable() async {
    await _stopBroadcaster();
    await _stopObserver();
    if (_peers.isNotEmpty) {
      _peers.clear();
      _log('Cleared peer list');
      _emit();
    }
  }

  // -------- Observer --------

  Future<void> _startObserver() async {
    if (_observer != null) return;
    _log('Starting observer for $serviceType');
    final observer = await _backend.observe(type: serviceType);
    _eventsSub = observer.events.listen(_onMdnsEvent);
    _observer = observer;
  }

  Future<void> _stopObserver() async {
    final o = _observer;
    if (o == null) return;
    _observer = null;
    _log('Stopping observer');
    await _eventsSub?.cancel();
    _eventsSub = null;
    await o.stop();
  }

  Future<void> _onMdnsEvent(MdnsEvent event) async {
    final svc = event.service;
    final id = svc.attributes[_kDeviceIdAttr];
    _log('Event ${event.kind.name} → name="${svc.name}" id=${id ?? "(none)"}');

    switch (event.kind) {
      case MdnsEventKind.found:
        // Resolution is handled by the backend; we'll get a `resolved`
        // event later with host/port populated.
        break;
      case MdnsEventKind.resolved:
        await _onResolved(svc);
      case MdnsEventKind.lost:
        if (id != null && _peers.remove(id) != null) {
          _log('Removed peer $id; peers=${_peers.length}');
          _emit();
        }
    }
  }

  Future<void> _onResolved(MdnsService svc) async {
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

    // Prefer the human-readable name from TXT; fall back to the mDNS
    // service name (which may have an NSD-collision suffix like "(2)").
    final displayName = svc.attributes[_kNameAttr] ?? svc.name;

    _peers[id] = Peer(
      id: id,
      name: displayName,
      host: svc.host,
      port: svc.port,
      // Pairing arrives in slice 4; until then everyone shows as unpaired.
      isPaired: false,
      lastSeen: DateTime.now(),
    );
    _log('Added peer name="$displayName" id=$id host=${svc.host}:${svc.port}; peers=${_peers.length}');
    _emit();
  }

  // -------- Broadcaster --------

  Future<void> _startBroadcaster() async {
    if (_broadcaster != null) return;
    final identity = await _identityRepo.get();

    // Session-unique mDNS name to avoid the platform NSD layer auto-
    // renaming on local-cache collision (the "(2)" issue from real-
    // device testing). The user-visible name lives in TXT.
    final sessionTag = _randomTag();
    final mdnsName = 'sharer-$sessionTag';

    _log('Starting broadcaster: mdnsName="$mdnsName" displayName="${identity.name}" id=${identity.id} port=$advertisedPort');
    final broadcaster = await _backend.broadcast(MdnsServiceSpec(
      name: mdnsName,
      type: serviceType,
      port: advertisedPort,
      attributes: {
        _kDeviceIdAttr: identity.id,
        _kNameAttr: identity.name,
      },
    ));
    _broadcaster = broadcaster;
    _setAnnouncing(true);
  }

  Future<void> _stopBroadcaster() async {
    final b = _broadcaster;
    if (b == null) return;
    _broadcaster = null;
    _log('Stopping broadcaster');
    await b.stop();
    _setAnnouncing(false);
  }

  String _randomTag() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _setAnnouncing(bool value) {
    if (_announcing == value) return;
    _announcing = value;
    _announcingController.add(value);
  }

  void _emit() {
    _latest = _peers.values.toList(growable: false);
    _peersController.add(_latest);
  }

  /// Logs to BOTH `developer.log` (DevTools-friendly, structured) and
  /// `debugPrint` (terminal-friendly, visible in `flutter run` and
  /// `adb logcat`). Real-device debugging needs the latter.
  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
