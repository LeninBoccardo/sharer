import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/hmac_signer.dart';

void main() {
  Uint8List psk(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  test('canonical string is deterministic for the same inputs', () {
    final a = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1700000000000,
      nonce: 'AAAA',
      senderDeviceId: 'sender-id',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 42,
    );
    final b = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1700000000000,
      nonce: 'AAAA',
      senderDeviceId: 'sender-id',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 42,
    );
    expect(a, equals(b));
  });

  test('canonical string changes when any field changes', () {
    final base = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1700000000000,
      nonce: 'AAAA',
      senderDeviceId: 'sender-id',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 42,
    );
    expect(
      canonicalString(
        method: 'GET',
        path: '/upload',
        timestampMs: 1700000000000,
        nonce: 'AAAA',
        senderDeviceId: 'sender-id',
        recipientDeviceId: 'recipient',
        filename: 'foo.txt',
        filesize: 42,
      ),
      isNot(equals(base)),
    );
    expect(
      canonicalString(
        method: 'POST',
        path: '/upload',
        timestampMs: 1700000000000,
        nonce: 'AAAA',
        senderDeviceId: 'sender-id',
        recipientDeviceId: 'recipient',
        filename: 'bar.txt',
        filesize: 42,
      ),
      isNot(equals(base)),
    );
    expect(
      canonicalString(
        method: 'POST',
        path: '/upload',
        timestampMs: 1700000000000,
        nonce: 'AAAA',
        senderDeviceId: 'sender-id',
        recipientDeviceId: 'recipient',
        filename: 'foo.txt',
        filesize: 43,
      ),
      isNot(equals(base)),
    );
  });

  test('canonical string changes when only recipientDeviceId changes '
      '(audit #30)', () {
    final a = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1700000000000,
      nonce: 'AAAA',
      senderDeviceId: 'sender-id',
      recipientDeviceId: 'recipient-a',
      filename: 'foo.txt',
      filesize: 42,
    );
    final b = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1700000000000,
      nonce: 'AAAA',
      senderDeviceId: 'sender-id',
      recipientDeviceId: 'recipient-b',
      filename: 'foo.txt',
      filesize: 42,
    );
    expect(a, isNot(equals(b)),
        reason: 'binding the recipient must change the signed canonical');
  });

  test('canonical string normalizes method case', () {
    final upper = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: 1,
      nonce: 'n',
      senderDeviceId: 'd',
      recipientDeviceId: 'recipient',
      filename: 'f',
      filesize: 0,
    );
    final lower = canonicalString(
      method: 'post',
      path: '/upload',
      timestampMs: 1,
      nonce: 'n',
      senderDeviceId: 'd',
      recipientDeviceId: 'recipient',
      filename: 'f',
      filesize: 0,
    );
    expect(upper, equals(lower));
  });

  test('signs with the canonical-string HMAC and a fresh nonce', () {
    final signer = HmacSigner(
      random: Random(0),
      now: () => DateTime.utc(2026, 5, 4, 10),
    );
    final h = signer.sign(
      psk: psk(1),
      method: 'POST',
      path: '/upload',
      senderDeviceId: 'sender',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 100,
    );

    expect(int.parse(h.timestamp), DateTime.utc(2026, 5, 4, 10).millisecondsSinceEpoch);
    expect(h.nonce, isNotEmpty);
    expect(base64Decode(h.nonce), hasLength(16));

    final canonical = canonicalString(
      method: 'POST',
      path: '/upload',
      timestampMs: int.parse(h.timestamp),
      nonce: h.nonce,
      senderDeviceId: 'sender',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 100,
    );
    final expected = Hmac(sha256, psk(1)).convert(utf8.encode(canonical));
    expect(h.signature, equals(base64Encode(expected.bytes)));
  });

  test('two consecutive sign calls produce different nonces', () {
    final signer = HmacSigner();
    final a = signer.sign(
      psk: psk(1),
      method: 'POST',
      path: '/upload',
      senderDeviceId: 'sender',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 0,
    );
    final b = signer.sign(
      psk: psk(1),
      method: 'POST',
      path: '/upload',
      senderDeviceId: 'sender',
      recipientDeviceId: 'recipient',
      filename: 'foo.txt',
      filesize: 0,
    );
    expect(a.nonce, isNot(equals(b.nonce)));
  });
}
