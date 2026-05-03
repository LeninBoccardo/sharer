class Peer {
  final String id;
  final String name;
  final String? host;
  final int? port;
  final bool isPaired;
  final DateTime lastSeen;

  const Peer({
    required this.id,
    required this.name,
    required this.lastSeen,
    this.host,
    this.port,
    this.isPaired = false,
  });

  bool get isReachable => host != null && port != null;

  Peer copyWith({
    String? name,
    String? host,
    int? port,
    bool? isPaired,
    DateTime? lastSeen,
  }) {
    return Peer(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      isPaired: isPaired ?? this.isPaired,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          host == other.host &&
          port == other.port &&
          isPaired == other.isPaired &&
          lastSeen == other.lastSeen;

  @override
  int get hashCode => Object.hash(id, name, host, port, isPaired, lastSeen);
}
