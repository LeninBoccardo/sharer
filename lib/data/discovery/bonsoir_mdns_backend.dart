import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'mdns_backend.dart';

/// Production [MdnsBackend] wrapping the bonsoir package. All bonsoir-
/// specific quirks (event ordering, TXT-record races, the resolve()
/// dance) are absorbed here so [MdnsPeerDiscovery] stays library-agnostic.
class BonsoirMdnsBackend implements MdnsBackend {
  @override
  Future<MdnsBroadcaster> broadcast(MdnsServiceSpec spec) async {
    final svc = BonsoirService(
      name: spec.name,
      type: spec.type,
      port: spec.port,
      attributes: spec.attributes,
    );
    final b = BonsoirBroadcast(service: svc);
    // bonsoir 6 renamed `ready` → `initialize()` and the event types
    // are now a sealed-class hierarchy instead of an enum on `.type`.
    await b.initialize();
    await b.start();
    return _BonsoirBroadcaster(b);
  }

  @override
  Future<MdnsObserver> observe({required String type}) async {
    final discovery = BonsoirDiscovery(type: type);
    await discovery.initialize();
    final controller = StreamController<MdnsEvent>.broadcast();

    // CRITICAL: subscribe BEFORE start(). bonsoir's eventStream is a
    // broadcast stream from EventChannel.receiveBroadcastStream(), which
    // does NOT buffer — events emitted by the platform between start()
    // returning and listen() attaching are dropped. Slice 2.3 caught
    // this on real Android devices.
    final sub = discovery.eventStream?.listen((event) async {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          controller.add(MdnsEvent(
            kind: MdnsEventKind.found,
            service: _toMdnsService(service),
          ));
          // Auto-resolve to get host/port. Bonsoir delivers a separate
          // BonsoirDiscoveryServiceResolvedEvent later.
          unawaited(service.resolve(discovery.serviceResolver));
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
          controller.add(MdnsEvent(
            kind: MdnsEventKind.resolved,
            service: _toMdnsService(service),
          ));
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          // Late TXT/host updates — surface as a fresh resolved event
          // so the orchestrator can pick up the new attributes.
          controller.add(MdnsEvent(
            kind: MdnsEventKind.resolved,
            service: _toMdnsService(service),
          ));
        case BonsoirDiscoveryServiceLostEvent(:final service):
          controller.add(MdnsEvent(
            kind: MdnsEventKind.lost,
            service: _toMdnsService(service),
          ));
        case BonsoirDiscoveryStartedEvent():
        case BonsoirDiscoveryStoppedEvent():
        case BonsoirDiscoveryServiceResolveFailedEvent():
        case BonsoirDiscoveryUnknownEvent():
          break;
      }
    });

    await discovery.start();
    return _BonsoirObserver(discovery, controller, sub);
  }

  /// In bonsoir 6 there is no separate `ResolvedBonsoirService` class —
  /// the same [BonsoirService] just has its nullable [host] populated
  /// once the resolve step succeeds. Treat host == null as unresolved.
  static MdnsService _toMdnsService(BonsoirService svc) {
    final host = svc.host;
    return MdnsService(
      name: svc.name,
      attributes: Map<String, String>.from(svc.attributes),
      host: host,
      port: host == null ? null : svc.port,
    );
  }
}

class _BonsoirBroadcaster implements MdnsBroadcaster {
  final BonsoirBroadcast _b;
  bool _stopped = false;

  _BonsoirBroadcaster(this._b);

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _b.stop();
  }
}

class _BonsoirObserver implements MdnsObserver {
  final BonsoirDiscovery _d;
  final StreamController<MdnsEvent> _controller;
  final StreamSubscription? _sub;
  bool _stopped = false;

  _BonsoirObserver(this._d, this._controller, this._sub);

  @override
  Stream<MdnsEvent> get events => _controller.stream;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _sub?.cancel();
    await _d.stop();
    await _controller.close();
  }
}
