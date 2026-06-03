import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/storage/favorites_store.dart';

void main() {
  late SharedPreferences prefs;
  late FavoritesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = FavoritesStore(prefs);
  });

  test('load is empty by default', () {
    expect(store.load(), isEmpty);
  });

  test('add then load round-trips; add is idempotent', () async {
    await store.add('a');
    await store.add('a');
    expect(store.load(), {'a'});
  });

  test('remove drops the id without touching others', () async {
    await store.add('a');
    await store.add('b');
    await store.remove('a');
    expect(store.load(), {'b'});
  });

  test('toggle adds+returns-true then removes+returns-false', () async {
    expect(await store.toggle('a'), isTrue);
    expect(store.contains('a'), isTrue);
    expect(await store.toggle('a'), isFalse);
    expect(store.contains('a'), isFalse);
  });

  test('favorites persist across store instances over the same prefs',
      () async {
    await store.add('x');
    final store2 = FavoritesStore(prefs);
    expect(store2.load(), {'x'});
  });
}
