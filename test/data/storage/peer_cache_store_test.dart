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

  group('slice 5.4 — cacheAddress + getById', () {
    test('cacheAddress mints a new entry when the deviceId is unknown',
        () async {
      await cache.cacheAddress(
        deviceId: 'fresh',
        host: '10.0.0.5',
        port: 8080,
        displayName: 'Fresh Phone',
      );
      final loaded = await cache.load();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'fresh');
      expect(loaded.first.host, '10.0.0.5');
      expect(loaded.first.port, 8080);
      expect(loaded.first.name, 'Fresh Phone');
      expect(loaded.first.isPaired, isTrue);
    });

    test('cacheAddress overwrites host/port on an existing entry without '
        'losing the name', () async {
      await cache.upsert(makePeer(id: 'p1', name: 'Phone'));
      await cache.cacheAddress(
        deviceId: 'p1',
        host: '10.0.0.99',
        port: 9090,
        // No displayName: must keep the previous name.
      );
      final loaded = await cache.load();
      expect(loaded.single.name, 'Phone');
      expect(loaded.single.host, '10.0.0.99');
      expect(loaded.single.port, 9090);
    });

    test('cacheAddress with a displayName updates it on existing entry',
        () async {
      await cache.upsert(makePeer(id: 'p1', name: 'Phone'));
      await cache.cacheAddress(
        deviceId: 'p1',
        host: '10.0.0.99',
        port: 9090,
        displayName: 'Phone (renamed)',
      );
      final loaded = await cache.load();
      expect(loaded.single.name, 'Phone (renamed)');
    });

    test('getById returns the entry or null', () async {
      await cache.upsert(makePeer(id: 'p1'));
      expect((await cache.getById('p1'))?.id, 'p1');
      expect(await cache.getById('not-there'), isNull);
    });
  });
}
