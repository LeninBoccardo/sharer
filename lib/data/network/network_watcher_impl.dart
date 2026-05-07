import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/entities/network_info.dart';
import '../../domain/repositories/network_watcher_repository.dart';
import 'network_source.dart';
import 'trusted_networks_store.dart';

const _logName = 'sharer.network';

void _log(String message) {
  developer.log(message, name: _logName);
  debugPrint('[$_logName] $message');
}

/// Reactive view of "what network are we on, and is it trusted?". Used to
/// gate mDNS announcements (quiet mode on unrecognized networks). The trust
/// boundary itself is the device pairing — see docs/v1/security.md.
class NetworkWatcherImpl implements NetworkWatcherRepository {
  /// Slice 5.x.4.2: periodic re-sample interval. connectivity_plus only
  /// fires on link transitions (Wi-Fi ↔ Ethernet ↔ none), not on
  /// IP renumbering — DHCP renew on the same SSID, Hyper-V vSwitch
  /// toggle on a wired interface, roaming to a different AP on the
  /// same SSID — all leave a stale ipv4 if we only react to that
  /// stream. 30 s is conservative but avoids hot-looping the OS API.
  static const _periodicResample = Duration(seconds: 30);

  final NetworkSource _source;
  final TrustedNetworksStore _trusted;

  final _network = StreamController<NetworkInfo?>.broadcast();
  final _isTrusted = StreamController<bool>.broadcast();
  final _trustedSet = StreamController<Set<String>>.broadcast();

  NetworkInfo? _latest;
  late Set<String> _trustedCache;
  StreamSubscription<void>? _sub;
  Timer? _periodicTimer;
  bool _disposed = false;

  NetworkWatcherImpl(this._source, this._trusted) {
    _trustedCache = _trusted.load();
    _sub = _source.connectivityChanges().listen((_) => _refresh());
    _periodicTimer = Timer.periodic(_periodicResample, (_) => _refresh());
    // Initial sample so consumers don't have to wait for the first change.
    unawaited(_refresh());
  }

  /// Slice 5.x.4.2: explicit re-sample for callers that have a
  /// stronger signal than the periodic timer — e.g., AppLifecycleState
  /// transitioning to resumed after a long pause.
  Future<void> recheck() => _refresh();

  Future<void> _refresh() async {
    if (_disposed) return;
    final info = await _source.read();
    final previous = _latest;
    _latest = info;
    final trusted = _evaluateTrust();
    // Slice 5.x.4.2: only emit when something downstream consumers
    // would actually care about changed. Avoids burning a redraw +
    // discovery-layer re-evaluation every 30 s when nothing moved.
    final changed = previous == null
        ? info != null
        : info == null || _infoDiffers(previous, info);
    if (!changed) return;
    _log(
      info == null
          ? 'Refresh → no network'
          : 'Refresh → ${info.linkType.name} ssid=${info.ssid ?? "—"} '
              'ip=${info.ipv4 ?? "—"} subnet=${info.subnet ?? "—"} '
              'fingerprint="${info.fingerprint}" trusted=$trusted',
    );
    _network.add(info);
    _isTrusted.add(trusted);
  }

  /// True if any field downstream consumers can observe changed —
  /// fingerprint (trust eval), ipv4 (server bind / discovery), ssid
  /// or linkType (UI labels).
  static bool _infoDiffers(NetworkInfo a, NetworkInfo b) {
    return a.fingerprint != b.fingerprint ||
        a.ipv4 != b.ipv4 ||
        a.ssid != b.ssid ||
        a.linkType != b.linkType;
  }

  bool _evaluateTrust() {
    final n = _latest;
    if (n == null) return false;
    return _trustedCache.contains(n.fingerprint);
  }

  void _emitTrustedSet() {
    _trustedSet.add(Set<String>.unmodifiable(_trustedCache));
  }

  @override
  Stream<NetworkInfo?> watch() async* {
    yield _latest;
    yield* _network.stream;
  }

  @override
  Future<NetworkInfo?> current() async => _latest ?? await _source.read();

  @override
  Future<void> trust(NetworkInfo info) async {
    _log('Trust → "${info.fingerprint}"');
    await _trusted.add(info.fingerprint);
    _trustedCache = _trusted.load();
    _isTrusted.add(_evaluateTrust());
    _emitTrustedSet();
  }

  @override
  Future<void> untrust(NetworkInfo info) async {
    await untrustFingerprint(info.fingerprint);
  }

  @override
  Future<void> untrustFingerprint(String fingerprint) async {
    _log('Untrust → "$fingerprint"');
    await _trusted.remove(fingerprint);
    _trustedCache = _trusted.load();
    _isTrusted.add(_evaluateTrust());
    _emitTrustedSet();
  }

  @override
  Stream<bool> watchIsTrusted() async* {
    yield _evaluateTrust();
    yield* _isTrusted.stream;
  }

  @override
  Stream<Set<String>> watchTrusted() async* {
    yield Set<String>.unmodifiable(_trustedCache);
    yield* _trustedSet.stream;
  }

  Future<void> dispose() async {
    _disposed = true;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await _sub?.cancel();
    await _network.close();
    await _isTrusted.close();
    await _trustedSet.close();
  }
}
