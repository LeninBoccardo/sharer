import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/in_flight_invite_store.dart';

import '../../fakes/fake_secure_key_value_store.dart';

InFlightInviteEntry _entry({
  String inviteId = 'i1',
  Duration? offset,
}) {
  final now = DateTime.utc(2026, 5, 6, 12);
  return InFlightInviteEntry(
    inviteId: inviteId,
    peerId: 'realme',
    peerName: 'Realme',
    peerHost: '192.168.68.56',
    peerPort: 8080,
    peerCertFingerprint: 'aa:bb:cc',
    senderId: 'lenin-pc',
    declineSignatureBase64: 'sig-$inviteId',
    expiresAt: now.add(offset ?? const Duration(minutes: 5)),
  );
}

void main() {
  late FakeSecureKeyValueStore secure;
  late InFlightInviteStore store;

  setUp(() {
    secure = FakeSecureKeyValueStore();
    store = InFlightInviteStore(secure);
  });

  test('get returns null when nothing has been saved', () async {
    expect(await store.get('i1'), isNull);
  });

  test('save then get round-trips an entry', () async {
    final saved = _entry();
    await store.save(saved);
    final loaded = await store.get('i1');
    expect(loaded, isNotNull);
    expect(loaded!.inviteId, 'i1');
    expect(loaded.peerHost, '192.168.68.56');
    expect(loaded.declineSignatureBase64, 'sig-i1');
    expect(loaded.expiresAt, saved.expiresAt);
  });

  test('save overwrites an existing entry with the same inviteId',
      () async {
    await store.save(_entry());
    final replacement = InFlightInviteEntry(
      inviteId: 'i1',
      peerId: 'realme',
      peerName: 'Realme',
      peerHost: '10.0.0.5', // changed
      peerPort: 9999, // changed
      peerCertFingerprint: 'aa:bb:cc',
      senderId: 'lenin-pc',
      declineSignatureBase64: 'new-sig',
      expiresAt: DateTime.utc(2026, 5, 6, 13),
    );
    await store.save(replacement);
    final loaded = await store.get('i1');
    expect(loaded?.peerHost, '10.0.0.5');
    expect(loaded?.peerPort, 9999);
    expect(loaded?.declineSignatureBase64, 'new-sig');
  });

  test('multiple inviteIds coexist', () async {
    await store.save(_entry(inviteId: 'a'));
    await store.save(_entry(inviteId: 'b'));
    expect((await store.get('a'))?.inviteId, 'a');
    expect((await store.get('b'))?.inviteId, 'b');
  });

  test('remove drops a specific inviteId without touching others',
      () async {
    await store.save(_entry(inviteId: 'a'));
    await store.save(_entry(inviteId: 'b'));
    await store.remove('a');
    expect(await store.get('a'), isNull);
    expect((await store.get('b'))?.inviteId, 'b');
  });

  test('remove on the last entry deletes the storage key (no empty '
      'JSON blob left behind)', () async {
    await store.save(_entry(inviteId: 'a'));
    await store.remove('a');
    // Reading the underlying secure store directly to verify the key
    // is gone, not just emptied to "{}".
    final raw = await secure.read('in_flight_invites_v1');
    expect(raw, isNull);
  });

  test('purgeExpired drops entries past their TTL', () async {
    final now = DateTime.utc(2026, 5, 6, 12);
    await store.save(_entry(
      inviteId: 'fresh',
      offset: const Duration(minutes: 5),
    ));
    await store.save(_entry(
      inviteId: 'stale',
      offset: const Duration(minutes: -1),
    ));
    await store.purgeExpired(now);
    expect((await store.get('fresh'))?.inviteId, 'fresh');
    expect(await store.get('stale'), isNull);
  });

  test('a corrupt blob is treated as empty (does not throw)', () async {
    await secure.write('in_flight_invites_v1', '{not-valid-json');
    expect(await store.get('whatever'), isNull);
    // Saving recovers — overwrites the corrupt blob.
    await store.save(_entry());
    expect((await store.get('i1'))?.inviteId, 'i1');
  });

  test('an entry with missing fields is dropped on read instead of '
      'crashing the whole map', () async {
    await secure.write(
      'in_flight_invites_v1',
      '{"good":{"inviteId":"good","peerId":"r","peerName":"R",'
          '"peerHost":"h","peerPort":1,"peerCertFingerprint":"x",'
          '"senderId":"s","declineSignatureBase64":"sig","expiresAt":'
          '"2026-05-06T13:00:00.000Z"},"bad":{"inviteId":"only this"}}',
    );
    expect((await store.get('good'))?.inviteId, 'good');
    expect(await store.get('bad'), isNull);
  });
}
