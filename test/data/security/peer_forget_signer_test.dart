import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/peer_forget_signer.dart';

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

const _ts = 1700000000000;
const _nonce = 'bm9uY2UtMTIz'; // arbitrary base64

void main() {
  test('signing the same v2 canonical with the same PSK is deterministic', () {
    final a = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    final b = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    expect(a.signature, b.signature);
    expect(a.timestamp, _ts.toString());
    expect(a.nonce, _nonce);
  });

  test('different sender id → different signature', () {
    final a = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    final b = signPeerForgotYou(
        psk: _psk(1), senderId: 'lenin-pc', timestampMs: _ts, nonce: _nonce);
    expect(a.signature, isNot(b.signature));
  });

  test('different PSK → different signature for the same sender', () {
    final a = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    final b = signPeerForgotYou(
        psk: _psk(99), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    expect(a.signature, isNot(b.signature));
  });

  test('changing only the nonce changes the signature (audit #23)', () {
    final a = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    final b = signPeerForgotYou(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts,
        nonce: 'b3RoZXItbm9uY2U=');
    expect(a.signature, isNot(b.signature));
  });

  test('changing only the timestamp changes the signature (audit #23)', () {
    final a = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    final b = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts + 1, nonce: _nonce);
    expect(a.signature, isNot(b.signature));
  });

  test('verify accepts a freshly signed token', () {
    final token = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts,
        nonce: _nonce,
        providedBase64: token.signature,
      ),
      isTrue,
    );
  });

  test('verify rejects a token signed with a different PSK', () {
    final token = signPeerForgotYou(
        psk: _psk(99), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts,
        nonce: _nonce,
        providedBase64: token.signature,
      ),
      isFalse,
    );
  });

  test('verify rejects a token signed for a different senderId', () {
    final token = signPeerForgotYou(
        psk: _psk(1), senderId: 'imposter', timestampMs: _ts, nonce: _nonce);
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts,
        nonce: _nonce,
        providedBase64: token.signature,
      ),
      isFalse,
    );
  });

  test('verify rejects a token whose timestamp was altered (bound to sig)',
      () {
    final token = signPeerForgotYou(
        psk: _psk(1), senderId: 'realme', timestampMs: _ts, nonce: _nonce);
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts + 1, // tampered
        nonce: _nonce,
        providedBase64: token.signature,
      ),
      isFalse,
    );
  });

  test('verify rejects malformed base64 without throwing', () {
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        timestampMs: _ts,
        nonce: _nonce,
        providedBase64: 'not!valid!base64!',
      ),
      isFalse,
    );
  });
}
