import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/in_flight_invite_store.dart';
import 'package:sharer/data/security/interrupted_pairing_detector.dart';

import '../../fakes/fake_secure_key_value_store.dart';

InFlightInviteEntry _entry(
  String id, {
  required DateTime expiresAt,
  String peerName = 'Realme',
  String peerId = 'realme',
}) =>
    InFlightInviteEntry(
      inviteId: id,
      peerId: peerId,
      peerName: peerName,
      peerHost: '192.168.1.5',
      peerPort: 8080,
      peerCertFingerprint: 'aa:bb:cc',
      senderId: 'lenin-pc',
      declineSignatureBase64: 'sig-$id',
      expiresAt: expiresAt,
    );

void main() {
  late FakeSecureKeyValueStore secure;
  late InFlightInviteStore store;
  late InterruptedPairingDetector detector;
  final now = DateTime.utc(2026, 6, 2, 12);

  setUp(() {
    secure = FakeSecureKeyValueStore();
    store = InFlightInviteStore(secure);
    detector = InterruptedPairingDetector(store);
  });

  test('empty mailbox -> null', () async {
    expect(await detector.detectAndConsume(now), isNull);
  });

  test('a non-expired leftover is reported as interrupted', () async {
    await store
        .save(_entry('i1', expiresAt: now.add(const Duration(minutes: 5))));
    final r = await detector.detectAndConsume(now);
    expect(r, isNotNull);
    expect(r!.inviteId, 'i1');
    expect(r.peerName, 'Realme');
    expect(r.peerId, 'realme');
  });

  test('an already-expired entry is not interrupted, and is purged', () async {
    await store
        .save(_entry('i1', expiresAt: now.subtract(const Duration(minutes: 1))));
    expect(await detector.detectAndConsume(now), isNull);
    expect(await store.get('i1'), isNull);
  });

  test('one-shot: a second call returns null and the mailbox is empty',
      () async {
    await store
        .save(_entry('i1', expiresAt: now.add(const Duration(minutes: 5))));
    expect((await detector.detectAndConsume(now))?.inviteId, 'i1');
    expect(await detector.detectAndConsume(now), isNull);
    expect((await store.readAll()).isEmpty, isTrue);
  });

  test('mixed expired + fresh: returns the fresh one and purges both',
      () async {
    await store.save(
        _entry('stale', expiresAt: now.subtract(const Duration(minutes: 1))));
    await store
        .save(_entry('fresh', expiresAt: now.add(const Duration(minutes: 5))));
    final r = await detector.detectAndConsume(now);
    expect(r?.inviteId, 'fresh');
    expect((await store.readAll()).isEmpty, isTrue);
  });

  test('expiresAt == now is treated as expired (agrees with purgeExpired)',
      () async {
    await store.save(_entry('i1', expiresAt: now));
    expect(await detector.detectAndConsume(now), isNull);
  });

  test('several fresh survivors -> returns the latest-expiring one', () async {
    await store.save(_entry('a', expiresAt: now.add(const Duration(minutes: 2))));
    await store.save(_entry('b', expiresAt: now.add(const Duration(minutes: 9))));
    await store.save(_entry('c', expiresAt: now.add(const Duration(minutes: 5))));
    final r = await detector.detectAndConsume(now);
    expect(r?.inviteId, 'b');
  });
}
