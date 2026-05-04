import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/data/identity/device_identity_store.dart';
import 'package:sharer/data/security/long_term_signer.dart';

import '../../fakes/fake_secure_key_value_store.dart';

void main() {
  late FakeSecureKeyValueStore secure;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = FakeSecureKeyValueStore();
  });

  test('first get() generates an Ed25519 keypair, persists seed + pubkey, '
      'derives deviceId from public key, resolves default name', () async {
    final prefs = await SharedPreferences.getInstance();
    var resolverCalls = 0;
    final store = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async {
        resolverCalls += 1;
        return 'Test Phone';
      },
    );

    final identity = await store.get();
    expect(identity.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(identity.name, 'Test Phone');
    expect(identity.publicKey, hasLength(32));
    expect(resolverCalls, 1);

    // Seed is persisted in secure storage (not prefs).
    final seed = secure.snapshot['device.identity.seed.v2'];
    expect(seed, isNotNull);
    expect(base64Decode(seed!), hasLength(32));

    // Public key + name in plain prefs.
    expect(prefs.getString('device.identity.publickey.v2'), isNotNull);
    expect(prefs.getString('device.identity.name'), 'Test Phone');

    // The derived deviceId matches LongTermSigner's fingerprint.
    final reconstructed = await LongTermSigner.fromSeed(base64Decode(seed));
    expect(identity.id, reconstructed.deviceIdFingerprint);
    expect(identity.publicKey, reconstructed.publicKey);
  });

  test('second get() reuses the persisted seed (stable identity across launches)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final first = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async => 'Test',
    );
    final original = await first.get();

    // Second store sees the same secure storage and prefs.
    final second = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async {
        fail('default-name resolver should not be invoked on reload');
      },
    );
    final reloaded = await second.get();

    expect(reloaded.id, original.id);
    expect(reloaded.publicKey, original.publicKey);
    expect(reloaded.name, original.name);
  });

  test('rename trims, persists, updates cache, and ignores blank input',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async => 'Old',
    );
    final original = await store.get();

    await store.rename('  New name  ');
    final renamed = await store.get();
    expect(renamed.name, 'New name');
    expect(renamed.id, original.id, reason: 'rename must not change identity');
    expect(prefs.getString('device.identity.name'), 'New name');

    await store.rename('   ');
    final unchanged = await store.get();
    expect(unchanged.name, 'New name');
  });

  test('migration: legacy UUID identity triggers reset and migration callback',
      () async {
    SharedPreferences.setMockInitialValues({
      'device.identity.id': 'legacy-uuid-from-slice-4.1',
      'device.identity.name': 'Old Name',
    });
    final prefs = await SharedPreferences.getInstance();

    var migrationCallbackInvoked = false;
    final store = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async => 'Should not appear',
      onMigrationReset: () async {
        migrationCallbackInvoked = true;
      },
    );

    final identity = await store.get();

    expect(identity.id, isNot('legacy-uuid-from-slice-4.1'),
        reason: 'legacy UUID must be replaced, not reused');
    expect(identity.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(identity.name, 'Old Name', reason: 'rename survives migration');
    expect(migrationCallbackInvoked, isTrue);
    expect(prefs.containsKey('device.identity.id'), isFalse,
        reason: 'legacy key should be removed');
    expect(secure.snapshot['device.identity.seed.v2'], isNotNull);
  });

  test('sign() produces an Ed25519 signature verifiable with the public key',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async => 'Signer',
    );
    final identity = await store.get();
    final message = Uint8List.fromList([42, 7, 13]);
    final sig = await store.sign(message);

    expect(sig, hasLength(64));
    final ok = await LongTermSigner.verify(
      message: message,
      signature: sig,
      publicKey: identity.publicKey,
    );
    expect(ok, isTrue);
  });

  test('sign() with the same store across calls is deterministic for Ed25519',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = DeviceIdentityStore(
      prefs,
      secure: secure,
      defaultName: () async => 'Signer',
    );
    await store.get();
    final m = Uint8List.fromList([1, 2, 3]);
    final a = await store.sign(m);
    final b = await store.sign(m);
    expect(a, equals(b),
        reason: 'Ed25519 is deterministic — same message + key → same sig');
  });
}
