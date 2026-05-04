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
  final NetworkSource _source;
  final TrustedNetworksStore _trusted;

  final _network = StreamController<NetworkInfo?>.broadcast();
  final _isTrusted = StreamController<bool>.broadcast();
  final _trustedSet = StreamController<Set<String>>.broadcast();

  NetworkInfo? _latest;
  late Set<String> _trustedCache;
  StreamSubscription<void>? _sub;
  bool _disposed = false;

  NetworkWatcherImpl(this._source, this._trusted) {
    _trustedCache = _trusted.load();
    _sub = _source.connectivityChanges().listen((_) => _refresh());
    // Initial sample so consumers don't have to wait for the first change.
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final info = await _source.read();
    _latest = info;
    final trusted = _evaluateTrust();
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
    await _sub?.cancel();
    await _network.close();
    await _isTrusted.close();
    await _trustedSet.close();
  }
}
