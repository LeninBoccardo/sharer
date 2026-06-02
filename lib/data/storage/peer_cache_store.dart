import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/peer_cache_repository.dart';

class PeerCacheStore implements PeerCacheRepository {
  static const _key = 'peers.cache.v1';

  /// Audit #38: bound the cache so it can't grow without limit (every
  /// HMAC-verified inbound can mint an entry) and so genuinely stale
  /// addresses get evicted. Entries last seen longer ago than this are
  /// pruned on hydration; the survivors are trimmed to [_maxEntries] by
  /// recency. Generous enough that a peer you pair with and use
  /// occasionally stays cached, tight enough that abandoned IPs go away.
  static const Duration _maxAge = Duration(days: 30);
  static const int _maxEntries = 50;

  final SharedPreferences _prefs;

  /// In-memory snapshot of the cache, lazily hydrated from
  /// SharedPreferences on first access. Every read goes here; every
  /// write goes here first and (conditionally) flushes to disk.
  ///
  /// Slice 5.x.2.2: previously every operation did
  /// load → JSON-decode → mutate → JSON-encode → setString. With three
  /// HMAC-verified inbound paths in `http_file_server.dart` calling
  /// [cacheAddress] per request, that's a measurable per-request stall
  /// at the start of a transfer where latency matters most.
  List<Peer>? _cache;

  PeerCacheStore(this._prefs);

  Future<List<Peer>> _ensureLoaded() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      return _cache = <Peer>[];
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    final list = decoded
        .map((e) => _fromJson(e as Map<String, dynamic>))
        .toList();
    final removed = _pruneStale(list, DateTime.now());
    _cache = list;
    // Only burn a disk write when the prune actually dropped something —
    // matches cacheAddress's "write only when state callers care about
    // changed" policy and keeps the common read-only hydration cheap.
    if (removed) await _persist();
    return list;
  }

  /// Audit #38: drop entries last seen longer ago than [_maxAge], then
  /// trim to the [_maxEntries] most-recently-seen. Mutates [list] in
  /// place. Returns true when anything was removed so callers can decide
  /// whether to flush. [now] is injected for testability.
  bool _pruneStale(List<Peer> list, DateTime now) {
    final before = list.length;
    final cutoff = now.subtract(_maxAge);
    list.removeWhere((p) => p.lastSeen.isBefore(cutoff));
    if (list.length > _maxEntries) {
      list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      list.removeRange(_maxEntries, list.length);
    }
    return list.length != before;
  }

  Future<void> _persist() async {
    final list = _cache;
    if (list == null) return;
    final encoded = jsonEncode(list.map(_toJson).toList());
    await _prefs.setString(_key, encoded);
  }

  @override
  Future<List<Peer>> load() async {
    return List<Peer>.unmodifiable(await _ensureLoaded());
  }

  @override
  Future<void> save(List<Peer> peers) async {
    _cache = List<Peer>.of(peers);
    await _persist();
  }

  @override
  Future<void> upsert(Peer peer) async {
    final list = await _ensureLoaded();
    final i = list.indexWhere((p) => p.id == peer.id);
    if (i >= 0) {
      list[i] = peer;
    } else {
      list.add(peer);
    }
    await _persist();
  }

  @override
  Future<void> remove(String peerId) async {
    final list = await _ensureLoaded();
    final before = list.length;
    list.removeWhere((p) => p.id == peerId);
    if (list.length != before) await _persist();
  }

  @override
  Future<void> cacheAddress({
    required String deviceId,
    required String host,
    required int port,
    String? displayName,
  }) async {
    final list = await _ensureLoaded();
    final i = list.indexWhere((p) => p.id == deviceId);
    final now = DateTime.now();
    if (i >= 0) {
      final existing = list[i];
      // Always refresh in-memory state so the current session sees the
      // latest lastSeen. Only burn a SharedPreferences write when
      // something callers will care about across restarts changed —
      // bumping lastSeen alone isn't worth the JSON-encode + disk
      // write per HMAC-verified inbound.
      final addrChanged =
          existing.host != host || existing.port != port;
      final nameChanged =
          displayName != null && existing.name != displayName;
      list[i] = existing.copyWith(
        host: host,
        port: port,
        lastSeen: now,
        // The display name on a Peer is mainly UI cosmetic; only
        // overwrite it when the caller actually has one. Keeps cached
        // names from being clobbered by signatures that omit them.
        name: displayName ?? existing.name,
      );
      if (addrChanged || nameChanged) await _persist();
    } else {
      list.add(Peer(
        id: deviceId,
        name: displayName ?? deviceId,
        host: host,
        port: port,
        isPaired: true,
        lastSeen: now,
      ));
      await _persist();
    }
  }

  @override
  Future<Peer?> getById(
    String deviceId, {
    Duration? freshFor,
    DateTime? now,
  }) async {
    final list = await _ensureLoaded();
    for (final p in list) {
      if (p.id != deviceId) continue;
      // Audit #38: when the caller asks for a fresh address, refuse to
      // hand back an entry older than freshFor so the send path falls
      // back to the live mDNS-resolved peer.host instead of dialing a
      // long-stale cached IP.
      if (freshFor != null) {
        final cutoff = (now ?? DateTime.now()).subtract(freshFor);
        if (p.lastSeen.isBefore(cutoff)) return null;
      }
      return p;
    }
    return null;
  }

  static Map<String, dynamic> _toJson(Peer p) => {
        'id': p.id,
        'name': p.name,
        if (p.host != null) 'host': p.host,
        if (p.port != null) 'port': p.port,
        'isPaired': p.isPaired,
        'lastSeen': p.lastSeen.toIso8601String(),
      };

  static Peer _fromJson(Map<String, dynamic> j) => Peer(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String?,
        port: j['port'] as int?,
        isPaired: (j['isPaired'] as bool?) ?? false,
        lastSeen: DateTime.parse(j['lastSeen'] as String),
      );
}
