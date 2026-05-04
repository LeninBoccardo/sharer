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
    await b.ready;
    await b.start();
    return _BonsoirBroadcaster(b);
  }

  @override
  Future<MdnsObserver> observe({required String type}) async {
    final discovery = BonsoirDiscovery(type: type);
    await discovery.ready;
    final controller = StreamController<MdnsEvent>.broadcast();

    // CRITICAL: subscribe BEFORE start(). bonsoir's eventStream is a
    // broadcast stream from EventChannel.receiveBroadcastStream(), which
    // does NOT buffer — events emitted by the platform between start()
    // returning and listen() attaching are dropped. Slice 2.3 caught
    // this on real Android devices.
    final sub = discovery.eventStream?.listen((event) async {
      final svc = event.service;
      switch (event.type) {
        case BonsoirDiscoveryEventType.discoveryServiceFound:
          if (svc != null) {
            controller.add(MdnsEvent(
              kind: MdnsEventKind.found,
              service: _toMdnsService(svc),
            ));
            // Auto-resolve to get host/port. Bonsoir delivers a separate
            // discoveryServiceResolved event later.
            unawaited(svc.resolve(discovery.serviceResolver));
          }
        case BonsoirDiscoveryEventType.discoveryServiceResolved:
          if (svc is ResolvedBonsoirService) {
            controller.add(MdnsEvent(
              kind: MdnsEventKind.resolved,
              service: _toMdnsService(svc),
            ));
          }
        case BonsoirDiscoveryEventType.discoveryServiceLost:
          if (svc != null) {
            controller.add(MdnsEvent(
              kind: MdnsEventKind.lost,
              service: _toMdnsService(svc),
            ));
          }
        case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
        case BonsoirDiscoveryEventType.discoveryStarted:
        case BonsoirDiscoveryEventType.discoveryStopped:
        case BonsoirDiscoveryEventType.unknown:
          break;
      }
    });

    await discovery.start();
    return _BonsoirObserver(discovery, controller, sub);
  }

  static MdnsService _toMdnsService(BonsoirService svc) {
    final host = svc is ResolvedBonsoirService ? svc.host : null;
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
