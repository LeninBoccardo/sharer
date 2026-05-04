/// What we want to publish on the network.
class MdnsServiceSpec {
  /// The mDNS instance name. **Must be unique per broadcast** to avoid
  /// the platform NSD layer auto-renaming on collision (e.g. bonsoir
  /// Android producing "Sharer (2)" when a previous broadcast hasn't
  /// fully expired in the local cache). Treat this as opaque — the
  /// human-readable name belongs in [MdnsServiceSpec.attributes] under
  /// `name`.
  final String name;
  final String type;
  final int port;
  final Map<String, String> attributes;

  const MdnsServiceSpec({
    required this.name,
    required this.type,
    required this.port,
    required this.attributes,
  });
}

/// A service we observed on the network.
class MdnsService {
  final String name;
  final Map<String, String> attributes;
  final String? host;
  final int? port;

  const MdnsService({
    required this.name,
    required this.attributes,
    this.host,
    this.port,
  });

  bool get isResolved => host != null && port != null;
}

enum MdnsEventKind { found, resolved, lost }

class MdnsEvent {
  final MdnsEventKind kind;
  final MdnsService service;

  const MdnsEvent({required this.kind, required this.service});
}

/// Backend abstraction for mDNS / DNS-SD broadcast + discovery.
///
/// Exists so the orchestration in [MdnsPeerDiscovery] (trust gating,
/// peer dedup, lifecycle) can be unit-tested without hitting real
/// platform sockets, and so the concrete library (currently bonsoir)
/// can be swapped without touching the orchestration.
abstract class MdnsBackend {
  /// Begin broadcasting [spec]. The returned handle is owned by the
  /// caller; call [MdnsBroadcaster.stop] to tear it down.
  Future<MdnsBroadcaster> broadcast(MdnsServiceSpec spec);

  /// Begin observing services of [type]. The implementation **must**
  /// auto-resolve found services and surface both `found` and
  /// `resolved` events on [MdnsObserver.events]. The returned
  /// observer's stream **must** deliver every event after subscription
  /// (no race-window drops — see slice 2.3 for the bug this rule
  /// prevents).
  Future<MdnsObserver> observe({required String type});
}

abstract class MdnsBroadcaster {
  Future<void> stop();
}

abstract class MdnsObserver {
  Stream<MdnsEvent> get events;

  Future<void> stop();
}
