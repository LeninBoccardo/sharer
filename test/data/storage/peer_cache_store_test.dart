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
    DateTime? lastSeen,
  }) =>
      Peer(
        id: id,
        name: name,
        host: host,
        port: port,
        isPaired: isPaired,
        lastSeen: lastSeen ?? DateTime.utc(2026, 5, 3, 12),
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

  group('audit #38 — freshness + prune', () {
    test('getById without freshFor returns the entry regardless of age', () async {
      // Regression guard for the default behaviour forget_service relies on.
      final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
      await cache.upsert(makePeer(id: 'p1', lastSeen: twoDaysAgo));
      expect((await cache.getById('p1'))?.id, 'p1');
    });

    test('getById with freshFor returns the entry when it is recent', () async {
      final now = DateTime.now();
      await cache.upsert(makePeer(id: 'p1', lastSeen: now));
      final got = await cache.getById('p1',
          freshFor: const Duration(hours: 12), now: now);
      expect(got?.host, isNotNull);
    });

    test('getById with freshFor returns null when the entry is stale', () async {
      final now = DateTime.now();
      await cache.upsert(
          makePeer(id: 'p1', lastSeen: now.subtract(const Duration(days: 2))));
      final got = await cache.getById('p1',
          freshFor: const Duration(hours: 12), now: now);
      expect(got, isNull);
    });

    test('prunes entries older than _maxAge on hydration and persists',
        () async {
      final now = DateTime.now();
      final stale =
          makePeer(id: 'old', lastSeen: now.subtract(const Duration(days: 40)));
      final recent =
          makePeer(id: 'new', lastSeen: now.subtract(const Duration(days: 1)));
      // save() does not prune; it just persists.
      await cache.save([stale, recent]);

      // A fresh store hydrating from the same prefs prunes the 40-day entry.
      final prefs = await SharedPreferences.getInstance();
      final store2 = PeerCacheStore(prefs);
      final loaded = await store2.load();
      expect(loaded.map((p) => p.id), ['new']);

      // The prune was persisted: a third store sees only the survivor.
      final store3 = PeerCacheStore(prefs);
      expect((await store3.load()).map((p) => p.id), ['new']);
    });

    test('trims to the 50 most-recently-seen on hydration', () async {
      final now = DateTime.now();
      // lastSeen increases with i (p59 most recent), all within _maxAge.
      final many = List.generate(
        60,
        (i) => makePeer(
            id: 'p$i', lastSeen: now.subtract(Duration(minutes: 60 - i))),
      );
      await cache.save(many);

      final prefs = await SharedPreferences.getInstance();
      final store2 = PeerCacheStore(prefs);
      final loaded = await store2.load();
      expect(loaded, hasLength(50));

      final ids = loaded.map((p) => p.id).toSet();
      // The 10 oldest (p0..p9) were dropped; the 50 most-recent survive.
      expect(ids.contains('p59'), isTrue);
      expect(ids.contains('p10'), isTrue);
      expect(ids.contains('p9'), isFalse);
      expect(ids.contains('p0'), isFalse);
    });
  });
}
