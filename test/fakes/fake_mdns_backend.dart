import 'dart:async';

import 'package:sharer/data/discovery/mdns_backend.dart';

/// Test double for [MdnsBackend]. Records every broadcast/observe call
/// and lets tests drive discovery events on demand. Tracks active vs
/// stopped handles so trust-transition tests can assert no leaks.
class FakeMdnsBackend implements MdnsBackend {
  final List<FakeBroadcaster> broadcasters = [];
  final List<FakeObserver> observers = [];

  /// Active (not stopped) broadcasters/observers. Use these in tests to
  /// avoid asserting on the cumulative list, which never shrinks.
  Iterable<FakeBroadcaster> get activeBroadcasters =>
      broadcasters.where((b) => !b.isStopped);

  Iterable<FakeObserver> get activeObservers =>
      observers.where((o) => !o.isStopped);

  @override
  Future<MdnsBroadcaster> broadcast(MdnsServiceSpec spec) async {
    final b = FakeBroadcaster(spec);
    broadcasters.add(b);
    return b;
  }

  @override
  Future<MdnsObserver> observe({required String type}) async {
    final o = FakeObserver(type);
    observers.add(o);
    return o;
  }
}

class FakeBroadcaster implements MdnsBroadcaster {
  final MdnsServiceSpec spec;
  bool isStopped = false;

  FakeBroadcaster(this.spec);

  @override
  Future<void> stop() async {
    isStopped = true;
  }
}

class FakeObserver implements MdnsObserver {
  final String type;
  final _controller = StreamController<MdnsEvent>.broadcast();
  bool isStopped = false;

  FakeObserver(this.type);

  @override
  Stream<MdnsEvent> get events => _controller.stream;

  @override
  Future<void> stop() async {
    isStopped = true;
    if (!_controller.isClosed) await _controller.close();
  }

  /// Test-only: push an event to the orchestrator.
  void emit(MdnsEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }
}
