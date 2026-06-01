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

  /// How long a peer may go without a fresh liveness signal (`found`,
  /// `resolved`, or a bonsoir TXT/host `updated` — which the backend
  /// already surfaces as `resolved`) before it is pruned from the list.
  /// bonsoir/NSD re-resolves a healthy peer on a ~30 s cadence (the same
  /// cadence the invite sweep and network resample already standardize
  /// on), so a TTL of ~2x that tolerates one missed re-announce yet
  /// still drops a genuinely-gone peer well inside a minute — even when
  /// bonsoir's `lost` event never fires (a known Android reliability
  /// gap; see reference_bonsoir_ip_flake).
  ///
  /// NOTE: the prune is only as good as the re-stamp cadence. If
  /// real-device testing (Realme + Lenin-PC) shows bonsoir does NOT
  /// re-emit resolved/updated for a still-present peer within this
  /// window, raise this constant or gate the prune — a vanished-but-
  /// alive peer is worse than a lingering dead one.
  static const _defaultPeerTtl = Duration(seconds: 60);

  /// How often the prune timer wakes. Cheap (a single map walk). A stale
  /// peer disappears within at most [_peerTtl] + this interval.
  static const _defaultPruneInterval = Duration(seconds: 30);

  /// Upper bound a *waiting* reconcile caller will block on the in-flight
  /// reconcile before giving up. The only thing a reconcile awaits is the
  /// backend's broadcast/observe/stop calls; bonsoir's `stop()` has been
  /// observed to wedge on Android teardown (see reference_bonsoir_ip_flake).
  /// Without this guard a wedged `stop()` would hang [dispose] — and thus
  /// app/provider teardown — forever. On timeout the waiter logs and
  /// returns; the in-flight reconcile is left to finish on its own.
  static const _defaultReconcileWaitTimeout = Duration(seconds: 5);

  final MdnsBackend _backend;
  final DeviceIdentityRepository _identityRepo;
  final Stream<bool> _isTrusted;
  final Random _random;
  final DateTime Function() _now;
  final Duration _peerTtl;
  final Duration _pruneInterval;
  final Duration _reconcileWaitTimeout;

  MdnsBroadcaster? _broadcaster;
  MdnsObserver? _observer;
  StreamSubscription<bool>? _trustSub;
  StreamSubscription<MdnsEvent>? _eventsSub;
  Timer? _pruneTimer;

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
  // Completed by the in-flight reconcile owner in its `finally`. A second
  // caller awaits this single future instead of polling the event loop.
  // Non-null exactly while [_reconcileInFlight] is true (both are set in
  // the owner's synchronous prologue before its first await).
  Completer<void>? _reconcileDone;

  MdnsPeerDiscovery({
    required MdnsBackend backend,
    required DeviceIdentityRepository identityRepo,
    required Stream<bool> isTrusted,
    Random? random,
    DateTime Function()? now,
    Duration peerTtl = _defaultPeerTtl,
    Duration pruneInterval = _defaultPruneInterval,
    Duration reconcileWaitTimeout = _defaultReconcileWaitTimeout,
  })  : _backend = backend,
        _identityRepo = identityRepo,
        _isTrusted = isTrusted,
        _random = random ?? Random(),
        _now = now ?? DateTime.now,
        _peerTtl = peerTtl,
        _pruneInterval = pruneInterval,
        _reconcileWaitTimeout = reconcileWaitTimeout;

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
    // stop() -> reconcile -> _disable() already cancels the timer on the
    // normal path; cancel again defensively so a dangling timer can
    // never outlive the object even if the teardown path changes.
    _stopPruneTimer();
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
      // A reconcile is already running. Queue our desired-state change so
      // the owner's convergence loop picks it up on its next iteration,
      // then await the owner's completion future — a single await, not a
      // microtask spin. The timeout is an escape hatch: a wedged backend
      // stop() must never hang dispose() forever (audit #16).
      _reconcileQueued = true;
      final done = _reconcileDone;
      if (done == null) return; // raced to completion; nothing to wait on.
      try {
        await done.future.timeout(_reconcileWaitTimeout);
      } on TimeoutException {
        _log('Reconcile wait timed out after '
            '${_reconcileWaitTimeout.inSeconds}s; proceeding without it');
      }
      return;
    }
    // We own this reconcile. Create the completion future BEFORE the first
    // await so any caller that observes _reconcileInFlight==true also sees
    // a non-null _reconcileDone to await.
    _reconcileInFlight = true;
    final done = _reconcileDone = Completer<void>();
    try {
      do {
        _reconcileQueued = false;
        await _applyDesiredState();
      } while (_reconcileQueued);
    } finally {
      _reconcileInFlight = false;
      _reconcileDone = null;
      if (!done.isCompleted) done.complete();
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
      _startPruneTimer();
    } catch (e, st) {
      _log('Enable failed: $e');
      developer.log('Enable failed', error: e, stackTrace: st, name: _logName);
      // Roll back to a clean state so the next reconcile can retry.
      await _disable();
      rethrow;
    }
  }

  Future<void> _disable() async {
    _stopPruneTimer();
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

  // -------- Prune (TTL expiry) --------

  void _startPruneTimer() {
    _pruneTimer ??= Timer.periodic(_pruneInterval, (_) => _prune());
  }

  void _stopPruneTimer() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
  }

  /// Re-stamp a known peer's lastSeen on any liveness signal. No-op for
  /// an unknown peer (a `found` may precede the first `resolved`, which
  /// creates the entry with a fresh stamp anyway).
  void _touchPeer(String id) {
    final p = _peers[id];
    if (p == null) return;
    _peers[id] = p.copyWith(lastSeen: _now());
  }

  /// Drops peers we haven't seen a liveness signal from within
  /// [_peerTtl]. bonsoir's `lost` event is unreliable on Android, so
  /// without this a silently-departed peer would linger forever and the
  /// user could tap a dead host:port on the share path. Only emits when
  /// it actually removed something, to avoid pointless stream churn.
  void _prune() {
    final now = _now();
    final stale = _peers.entries
        .where((e) => now.difference(e.value.lastSeen) > _peerTtl)
        .map((e) => e.key)
        .toList(growable: false);
    if (stale.isEmpty) return;
    for (final id in stale) {
      _peers.remove(id);
    }
    _log('Pruned ${stale.length} stale peer(s); peers=${_peers.length}');
    _emit();
  }

  /// Test-only hook so the prune can be driven synchronously after
  /// advancing an injected clock, without waiting on the real timer.
  @visibleForTesting
  void prunePeers() => _prune();

  Future<void> _onMdnsEvent(MdnsEvent event) async {
    final svc = event.service;
    final id = svc.attributes[_kDeviceIdAttr];
    _log('Event ${event.kind.name} → name="${svc.name}" id=${id ?? "(none)"}');

    switch (event.kind) {
      case MdnsEventKind.found:
        // Resolution is handled by the backend; we'll get a `resolved`
        // event later with host/port populated. But if this is a
        // re-`found` of a peer we already know, treat it as a liveness
        // signal and re-stamp lastSeen — extra insurance for the TTL
        // prune (audit #2) so a peer bonsoir is still browsing isn't
        // dropped just because it hasn't re-`resolved` within the TTL.
        if (id != null) _touchPeer(id);
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
      lastSeen: _now(),
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
