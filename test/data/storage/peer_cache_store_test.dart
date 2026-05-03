import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/storage/peer_cache_store.dart';
import 'package:sharer/domain/entities/peer.dart';

void main() {
  late PeerCacheStore cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    cache = PeerCacheStore(prefs);
  });

  Peer makePeer({
    String id = 'p1',
    String name = 'Phone',
    String? host = '192.168.1.42',
    int? port = 8080,
    bool isPaired = true,
  }) =>
      Peer(
        id: id,
        name: name,
        host: host,
        port: port,
        isPaired: isPaired,
        lastSeen: DateTime.utc(2026, 5, 3, 12),
      );

  test('load returns empty when nothing has been saved', () async {
    expect(await cache.load(), isEmpty);
  });

  test('save then load round-trips peers', () async {
    final peers = [makePeer(), makePeer(id: 'p2', name: 'Laptop')];
    await cache.save(peers);
    expect(await cache.load(), equals(peers));
  });

  test('upsert adds new peer and replaces existing by id', () async {
    final original = makePeer();
    await cache.upsert(original);
    expect(await cache.load(), [original]);

    final renamed = makePeer(name: 'Phone (renamed)');
    await cache.upsert(renamed);
    final loaded = await cache.load();
    expect(loaded, [renamed]);
    expect(loaded.single.name, 'Phone (renamed)');
  });

  test('remove drops the matching id', () async {
    await cache.save([makePeer(), makePeer(id: 'p2', name: 'Laptop')]);
    await cache.remove('p1');
    final loaded = await cache.load();
    expect(loaded.map((p) => p.id), ['p2']);
  });
}
