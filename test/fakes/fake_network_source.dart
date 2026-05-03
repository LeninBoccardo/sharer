import 'dart:async';

import 'package:sharer/data/network/network_source.dart';
import 'package:sharer/domain/entities/network_info.dart';

class FakeNetworkSource implements NetworkSource {
  final _controller = StreamController<void>.broadcast();
  NetworkInfo? _current;

  FakeNetworkSource({NetworkInfo? initial}) : _current = initial;

  /// Push a new network state and notify subscribers, mirroring how a real
  /// connectivity-change event would trigger a re-read.
  void emit(NetworkInfo? info) {
    _current = info;
    _controller.add(null);
  }

  @override
  Stream<void> connectivityChanges() => _controller.stream;

  @override
  Future<NetworkInfo?> read() async => _current;

  Future<void> dispose() => _controller.close();
}
