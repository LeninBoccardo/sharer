import 'dart:async';

import '../../domain/entities/network_info.dart';
import '../../domain/repositories/network_watcher_repository.dart';
import 'network_source.dart';
import 'trusted_networks_store.dart';

/// Reactive view of "what network are we on, and is it trusted?". Used to
/// gate mDNS announcements (quiet mode on unrecognized networks). The trust
/// boundary itself is the device pairing — see docs/v1/security.md.
class NetworkWatcherImpl implements NetworkWatcherRepository {
  final NetworkSource _source;
  final TrustedNetworksStore _trusted;

  final _network = StreamController<NetworkInfo?>.broadcast();
  final _isTrusted = StreamController<bool>.broadcast();

  NetworkInfo? _latest;
  StreamSubscription<void>? _sub;
  bool _disposed = false;

  NetworkWatcherImpl(this._source, this._trusted) {
    _sub = _source.connectivityChanges().listen((_) => _refresh());
    // Initial sample so consumers don't have to wait for the first change.
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final info = await _source.read();
    _latest = info;
    _network.add(info);
    _isTrusted.add(_evaluateTrust());
  }

  bool _evaluateTrust() {
    final n = _latest;
    if (n == null) return false;
    return _trusted.contains(n.fingerprint);
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
    await _trusted.add(info.fingerprint);
    _isTrusted.add(_evaluateTrust());
  }

  @override
  Future<void> untrust(NetworkInfo info) async {
    await _trusted.remove(info.fingerprint);
    _isTrusted.add(_evaluateTrust());
  }

  @override
  Stream<bool> watchIsTrusted() async* {
    yield _evaluateTrust();
    yield* _isTrusted.stream;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    await _network.close();
    await _isTrusted.close();
  }
}
