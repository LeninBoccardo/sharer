import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:sharer/data/security/hmac_signer.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/domain/entities/paired_device.dart';

import '../../fakes/fake_secure_key_value_store.dart';

/// Build a fake [Request] matching the shape the production server
/// hands to the verifier (POST /upload). Tests override path/method
/// only when they need to exercise drift cases.
Request _fakeRequest({
  String method = 'POST',
  String path = '/upload',
}) =>
    Request(method, Uri.parse('http://localhost$path'));

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
    verifier = HmacVerifier(paired,
        localDeviceId: Future.value('local-recipient'), now: () => now);
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
      request: _fakeRequest(),
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
      request: _fakeRequest(),
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
      request: _fakeRequest(),
      senderDeviceId: 'sender',
      timestamp: '1700000000000',
      nonce: null,
      signature: 'AA',
      filename: 'foo.txt',
      filesize: 0,
    );
    expect(result, isA<HmacRejected>());
  });

  test('rejects when the request path does not match the signed path',
      () async {
    // Slice 5.x.2.4: the verifier now derives method+path from the
    // Request itself rather than trusting caller-passed strings. A
    // peer's `/upload` signature must not validate when replayed
    // against a different path.
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifier.verify(
      request: _fakeRequest(path: '/different-path'),
      senderDeviceId: peer.deviceId,
      timestamp: headers.timestamp,
      nonce: headers.nonce,
      signature: headers.signature,
      filename: 'foo.txt',
      filesize: 100,
    );
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).detail, contains('signature'));
  });

  test('returns Rejected for unknown sender', () async {
    final peer = makePeer();
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    // Did NOT add peer to repo.
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).detail, contains('unknown sender'));
    // Audit #1: unknown-sender is the only reason that drives reactive
    // forget on the wire (mapped to 403 + X-Sharer-Reason by the server).
    expect(result.reason, HmacRejectionReason.unknownSender);
  });

  test('accepts a valid signed request from a paired peer', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacAuthenticated>());
    expect((result as HmacAuthenticated).device.deviceId, peer.deviceId);
  });

  test('rejects a signature minted for a DIFFERENT recipient (audit #30)',
      () async {
    // Same PSK, same sender — but the signer bound a different recipient id
    // than this verifier's own localDeviceId ('local-recipient'), so the
    // reconstructed canonical differs and the signature must not verify.
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'other-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).detail, contains('signature'));
    // A recipient mismatch is a recoverable signing failure, NOT an unpair
    // signal — must stay transient (bare 401, never reactive-forget).
    expect(result.reason, HmacRejectionReason.transient);
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
      recipientDeviceId: 'local-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: headers);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).detail, contains('signature'));
  });

  test('rejects when filename in canonical string does not match', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
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
      recipientDeviceId: 'local-recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final result = await verifyFromHeaders(peer: peer, headers: stale);
    expect(result, isA<HmacRejected>());
    expect((result as HmacRejected).detail, contains('timestamp'));
    // Audit #1: clock skew is a transient failure — it must NOT unpair a
    // still-valid peer, so it stays a bare 401 (no reason header).
    expect(result.reason, HmacRejectionReason.transient);
  });

  test('rejects replayed nonce within the TTL window', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
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
        localDeviceId: Future.value('local-recipient'),
        now: () => now,
        nonceTtl: const Duration(seconds: 60));

    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
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
    expect((result as HmacRejected).detail, contains('timestamp'));
  });

  test('rejects malformed signature (non-base64)', () async {
    final peer = makePeer();
    await paired.add(peer);
    final headers = signer.sign(
      psk: peer.psk,
      method: 'POST',
      path: '/upload',
      senderDeviceId: peer.deviceId,
      recipientDeviceId: 'local-recipient',
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

  group('checkFreshness (audit #23 — shared by /peer-forgot-you)', () {
    String tsNow() => now.toUtc().millisecondsSinceEpoch.toString();

    test('fresh timestamp + unseen nonce returns fresh and records it', () {
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: tsNow(), nonce: 'n1'),
        FreshnessResult.fresh,
      );
      // Immediate replay of the same (sender, nonce) is rejected.
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: tsNow(), nonce: 'n1'),
        FreshnessResult.replayed,
      );
    });

    test('stale timestamp (outside window) returns staleTimestamp', () {
      final old = now
          .subtract(const Duration(minutes: 5))
          .toUtc()
          .millisecondsSinceEpoch
          .toString();
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: old, nonce: 'n2'),
        FreshnessResult.staleTimestamp,
      );
    });

    test('future timestamp (outside window) returns staleTimestamp', () {
      final future = now
          .add(const Duration(minutes: 5))
          .toUtc()
          .millisecondsSinceEpoch
          .toString();
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: future, nonce: 'n3'),
        FreshnessResult.staleTimestamp,
      );
    });

    test('malformed timestamp returns staleTimestamp', () {
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: 'abc', nonce: 'n4'),
        FreshnessResult.staleTimestamp,
      );
    });

    test('empty or missing nonce returns replayed', () {
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: tsNow(), nonce: ''),
        FreshnessResult.replayed,
      );
      expect(
        verifier.checkFreshness(
            senderDeviceId: 'peer', timestamp: tsNow(), nonce: null),
        FreshnessResult.replayed,
      );
    });
  });
}
