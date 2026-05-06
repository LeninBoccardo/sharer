import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/peer_forget_signer.dart';

Uint8List _psk(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

void main() {
  test('signing the same canonical with the same PSK is deterministic', () {
    final a = signPeerForgotYou(psk: _psk(1), senderId: 'realme');
    final b = signPeerForgotYou(psk: _psk(1), senderId: 'realme');
    expect(a, b);
  });

  test('different sender id → different signature', () {
    final a = signPeerForgotYou(psk: _psk(1), senderId: 'realme');
    final b = signPeerForgotYou(psk: _psk(1), senderId: 'lenin-pc');
    expect(a, isNot(b));
  });

  test('different PSK → different signature for the same sender', () {
    final a = signPeerForgotYou(psk: _psk(1), senderId: 'realme');
    final b = signPeerForgotYou(psk: _psk(99), senderId: 'realme');
    expect(a, isNot(b));
  });

  test('verify accepts a freshly signed token', () {
    final sig = signPeerForgotYou(psk: _psk(1), senderId: 'realme');
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        providedBase64: sig,
      ),
      isTrue,
    );
  });

  test('verify rejects a token signed with a different PSK', () {
    final sig = signPeerForgotYou(psk: _psk(99), senderId: 'realme');
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        providedBase64: sig,
      ),
      isFalse,
    );
  });

  test('verify rejects a token signed for a different senderId', () {
    final sig = signPeerForgotYou(psk: _psk(1), senderId: 'imposter');
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        providedBase64: sig,
      ),
      isFalse,
    );
  });

  test('verify rejects malformed base64 without throwing', () {
    expect(
      verifyPeerForgotYouSignature(
        psk: _psk(1),
        senderId: 'realme',
        providedBase64: 'not!valid!base64!',
      ),
      isFalse,
    );
  });
}
