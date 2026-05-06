import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/peer_cache_repository.dart';

class PeerCacheStore implements PeerCacheRepository {
  static const _key = 'peers.cache.v1';

  final SharedPreferences _prefs;

  PeerCacheStore(this._prefs);

  @override
  Future<List<Peer>> load() async {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => _fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<void> save(List<Peer> peers) async {
    final encoded = jsonEncode(peers.map(_toJson).toList());
    await _prefs.setString(_key, encoded);
  }

  @override
  Future<void> upsert(Peer peer) async {
    final list = (await load()).toList();
    final i = list.indexWhere((p) => p.id == peer.id);
    if (i >= 0) {
      list[i] = peer;
    } else {
      list.add(peer);
    }
    await save(list);
  }

  @override
  Future<void> remove(String peerId) async {
    final list = (await load()).where((p) => p.id != peerId).toList();
    await save(list);
  }

  @override
  Future<void> cacheAddress({
    required String deviceId,
    required String host,
    required int port,
    String? displayName,
  }) async {
    final list = (await load()).toList();
    final i = list.indexWhere((p) => p.id == deviceId);
    final now = DateTime.now();
    if (i >= 0) {
      list[i] = list[i].copyWith(
        host: host,
        port: port,
        lastSeen: now,
        // The display name on a Peer is mainly UI cosmetic; only
        // overwrite it when the caller actually has one. Keeps cached
        // names from being clobbered by signatures that omit them.
        name: displayName ?? list[i].name,
      );
    } else {
      list.add(Peer(
        id: deviceId,
        name: displayName ?? deviceId,
        host: host,
        port: port,
        isPaired: true,
        lastSeen: now,
      ));
    }
    await save(list);
  }

  @override
  Future<Peer?> getById(String deviceId) async {
    final list = await load();
    for (final p in list) {
      if (p.id == deviceId) return p;
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
