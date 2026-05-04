import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_secure_key_value_store.dart';

void main() {
  late FakeSecureKeyValueStore secure;
  late PairedDevicesStore store;

  setUp(() {
    secure = FakeSecureKeyValueStore();
    store = PairedDevicesStore(secure);
  });

  tearDown(() => store.dispose());

  Uint8List psk(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  PairedDevice make({
    String deviceId = 'realme',
    String displayName = 'Realme',
    int seed = 1,
    String? certFingerprint,
    DateTime? pairedAt,
  }) =>
      PairedDevice(
        deviceId: deviceId,
        displayName: displayName,
        psk: psk(seed),
        publicKey: Uint8List.fromList(
            List<int>.generate(32, (i) => (200 + seed + i) & 0xff)),
        certFingerprint: certFingerprint,
        pairedAt: pairedAt ?? DateTime.utc(2026, 5, 4, 10),
      );

  test('getAll returns empty when nothing has been added', () async {
    expect(await store.getAll(), isEmpty);
  });

  test('add then get round-trips a device including PSK and fingerprint',
      () async {
    final dev = make(certFingerprint: 'sha256:abc');
    await store.add(dev);
    expect(await store.get('realme'), equals(dev));
  });

  test('add persists to underlying secure storage with prefixed key',
      () async {
    await store.add(make());
    expect(secure.snapshot.keys.single, startsWith('paired_device:'));
    expect(secure.snapshot.keys.single, endsWith('realme'));
  });

  test('a fresh store loads paired devices from disk', () async {
    await store.add(make());
    await store.dispose();

    final reloaded = PairedDevicesStore(secure);
    addTearDown(reloaded.dispose);
    expect(await reloaded.getAll(), [make()]);
  });

  test('add with same deviceId replaces the previous entry', () async {
    await store.add(make(displayName: 'Realme'));
    await store.add(make(displayName: 'Realme (renamed)'));
    final all = await store.getAll();
    expect(all, hasLength(1));
    expect(all.single.displayName, 'Realme (renamed)');
  });

  test('remove drops the entry from storage and cache', () async {
    await store.add(make(deviceId: 'a'));
    await store.add(make(deviceId: 'b', seed: 2));
    await store.remove('a');
    expect((await store.getAll()).map((d) => d.deviceId), ['b']);
    expect(secure.snapshot.keys, ['paired_device:b']);
  });

  test('remove on unknown id is a no-op', () async {
    await store.add(make());
    await store.remove('nope');
    expect((await store.getAll()).single.deviceId, 'realme');
  });

  test('watch emits current state on subscribe and on every change',
      () async {
    await store.add(make(deviceId: 'a'));

    final emitted = <List<PairedDevice>>[];
    final sub = store.watch().listen(emitted.add);
    await pumpEventQueue();
    expect(emitted, hasLength(1));
    expect(emitted.first.single.deviceId, 'a');

    await store.add(make(deviceId: 'b', seed: 2));
    await pumpEventQueue();
    expect(emitted, hasLength(2));
    expect(emitted.last.map((d) => d.deviceId), ['a', 'b']);

    await store.remove('a');
    await pumpEventQueue();
    expect(emitted, hasLength(3));
    expect(emitted.last.map((d) => d.deviceId), ['b']);

    await sub.cancel();
  });

  test('corrupt entries are dropped from disk on load', () async {
    // 32 zero bytes encoded as base64 → 43 'A's + '=' padding.
    const validPsk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    const validPub = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    await secure.write('paired_device:legit',
        '{"deviceId":"legit","displayName":"Legit","psk":"$validPsk","publicKey":"$validPub","pairedAt":"2026-05-04T10:00:00.000Z"}');
    await secure.write('paired_device:broken', '{not valid json');
    await secure.write('something_else', 'untouched');

    final fresh = PairedDevicesStore(secure);
    addTearDown(fresh.dispose);

    final all = await fresh.getAll();
    expect(all.single.deviceId, 'legit');
    expect(secure.snapshot.containsKey('paired_device:broken'), isFalse,
        reason: 'corrupt entry should be removed from disk');
    expect(secure.snapshot.containsKey('something_else'), isTrue,
        reason: 'unrelated keys must not be touched');
  });

  test('readAll filters by prefix — unrelated keys are ignored', () async {
    await secure.write('unrelated', 'value');
    await store.add(make());
    expect((await store.getAll()).map((d) => d.deviceId), ['realme']);
  });
}
