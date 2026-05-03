import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/identity/device_identity_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first get() generates an id, persists, and resolves the default name',
      () async {
    final prefs = await SharedPreferences.getInstance();
    var resolverCalls = 0;
    final store = DeviceIdentityStore(
      prefs,
      defaultName: () async {
        resolverCalls += 1;
        return 'Test Phone';
      },
    );

    final id = await store.get();
    expect(id.id, isNotEmpty);
    expect(id.name, 'Test Phone');
    expect(resolverCalls, 1);

    expect(prefs.getString('device.identity.id'), id.id);
    expect(prefs.getString('device.identity.name'), 'Test Phone');
  });

  test('second get() reuses persisted name without invoking the resolver',
      () async {
    SharedPreferences.setMockInitialValues({
      'device.identity.id': 'persisted-id',
      'device.identity.name': 'Persisted Name',
    });
    final prefs = await SharedPreferences.getInstance();
    var resolverCalls = 0;
    final store = DeviceIdentityStore(
      prefs,
      defaultName: () async {
        resolverCalls += 1;
        return 'Should not appear';
      },
    );

    final id = await store.get();
    expect(id.id, 'persisted-id');
    expect(id.name, 'Persisted Name');
    expect(resolverCalls, 0);
  });

  test('rename trims, persists, updates cache, and ignores blank input',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = DeviceIdentityStore(
      prefs,
      defaultName: () async => 'Old',
    );

    await store.get();
    await store.rename('  New name  ');
    final id = await store.get();
    expect(id.name, 'New name');
    expect(prefs.getString('device.identity.name'), 'New name');

    await store.rename('   ');
    final after = await store.get();
    expect(after.name, 'New name'); // unchanged
  });
}
