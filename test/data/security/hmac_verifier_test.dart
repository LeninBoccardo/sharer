import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/hmac_signer.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_secure_key_value_store.dart';

void main() {
  late FakeSecureKeyValueStore secure;
  late PairedDevicesStore paired;
  late DateTime now;
  late HmacVerifier verifier;
  late HmacSigner signer;

  Uint8List psk(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  PairedDevice makePeer({String id = 'peer', int seed = 1}) => PairedDevice(
        deviceId: id,
        displayName: 'Peer',
        psk: psk(seed),
        publicKey: Uint8List.fromList(
            List<int>.generate(32, (i) => (200 + seed + i) & 0xff)),
        pairedAt: DateTime.utc(2026, 5, 4),
      );

  setUp(() async {
    secure = FakeSecureKeyValueStore();
    paired = PairedDevicesStore(secure);
    now = DateTime.utc(2026, 5, 4, 12);
    verifier = HmacVerifier(paired, now: () => now);
    signer = HmacSigner(random: Random(0), now: () => now);
  });

  tearDown(() => paired.dispose());

  Future<HmacVerifyResult> verifyFromHeaders({
    required PairedDevice peer,
    required SignedRequestHeaders headers,
    String filename = 'foo.txt',
    int filesize = 100,
    String? overrideTimestamp,
    String? overrideNonce,
    String? overrideSignature,
    String? overrideSender,
  }) {
    return verifier.verify(
      method: 'POST',
      path: '/upload',
      senderDeviceId: overrideSender ?? peer.deviceId,
      timestamp: overrideTimestamp ?? headers.timestamp,
      nonce: overrideNonce ?? headers.nonce,
      signature: overrideSignature ?? headers.signature,
      filename: filename,
      filesize: filesize,
    );
  }

  test('returns Unsigned when no signature headers are present', () async {
    final result = await verifier.verify(
      method: 'POST',
      path: '/upload',
      senderDeviceId: 'sender',
      timestamp: null,
      nonce: null,
      signature: null,
      filename: 'foo.txt',
      filesize: 0,
    );
    expect(result, isA<HmacUnsigned>());
  });

  test('returns Rejected when only some signature headers are present',
      () async {
    final result = await verifier.verify(
      method: 'POST',
      path: '/upload',
      senderDeviceId: 'sender',
      timestamp: '1700000000000',
      nonce: null,
      signature: 'AA',
      filename: 'foo.txt',
      filesize: 0,
    );
    expect(result, isA<HmacRejected>());
  });

  test('returns Rejected for unknown sender', () async {
    final peer = makePeer();
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    // Did NOT add peer to repo.
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).reason, contains('unknown sender'));
  });

  test('accepts a valid signed request from a paired peer', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacAuthenticated>());
    expect((result as HmacAuthenticated).device.deviceId, peer.deviceId);
  });

  test('rejects when signed with a different PSK than the peer registered',
      () async {
    final peer = makePeer(seed: 1);
    await paired.add(peer);
    final attackerSigner = signer;
    final headers = attackerSigner.sign(
      psk: psk(99), // wrong PSK
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).reason, contains('signature'));
  });

  test('rejects when filename in canonical string does not match', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(
      peer: peer,
      headers: headers,
      filename: 'bar.txt', // mismatched
    );
    expect(result, isA<HmacRejected>());
  });

  test('rejects timestamp outside the clock-skew window', () async {
    final peer = makePeer();
    await paired.add(peer);
    final past = now.subtract(const Duration(minutes: 5));
    final stale = HmacSigner(random: Random(0), now: () => past).sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: stale);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).reason, contains('timestamp'));
  });

  test('rejects replayed nonce within the TTL window', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    expect(await verifyFromHeaders(peer: peer, headers: headers),
        isA<HmacAuthenticated>());
    // Same nonce immediately afterwards should be rejected.
    expect(await verifyFromHeaders(peer: peer, headers: headers),
        isA<HmacRejected>());
  });

  test('replay buffer purges entries older than the nonce TTL', () async {
    final peer = makePeer();
    await paired.add(peer);
    verifier = HmacVerifier(paired,
        now: () => now, nonceTtl: const Duration(seconds: 60));

    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    expect(await verifyFromHeaders(peer: peer, headers: headers),
        isA<HmacAuthenticated>());

    // Advance the clock past the TTL but reuse the same nonce. The buffer
    // entry expires; still rejected because the timestamp is now stale,
    // *not* because of replay — different reason confirms the entry left.
    now = now.add(const Duration(seconds: 120));
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).reason, contains('timestamp'));
  });

  test('rejects malformed signature (non-base64)', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(
      peer: peer,
      headers: headers,
      overrideSignature: '!!!not-base64!!!',
    );
    expect(result, isA<HmacRejected>());
  });
}
