import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Slice 5.4 — canonical input for `/peer-forgot-you` HMAC.
///
/// The wire body shape is intentionally minimal:
///
/// ```json
/// { "senderId": "<deviceId>", "signature": "<base64 HMAC>" }
/// ```
///
/// The HMAC covers `sharer-peer-forgot-you-v1\n<senderId>` so a peer
/// can't replay another peer's notification (each pair has its own PSK,
/// and each peer signs as itself).

const String _verbForgotYou = 'sharer-peer-forgot-you-v1';

List<int> peerForgotYouCanonical({required String senderId}) {
  return utf8.encode([
    _verbForgotYou,
    senderId,
  ].join('\n'));
}

/// Returns the base64-encoded HMAC-SHA256 signature for a peer-forgot-you
/// request signed by [psk].
String signPeerForgotYou({
  required Uint8List psk,
  required String senderId,
}) {
  final mac = Hmac(sha256, psk).convert(peerForgotYouCanonical(senderId: senderId));
  return base64Encode(mac.bytes);
}

/// Constant-time comparison of an inbound base64 signature against the
/// expected HMAC for [senderId] with [psk]. Returns true on a match.
bool verifyPeerForgotYouSignature({
  required Uint8List psk,
  required String senderId,
  required String providedBase64,
}) {
  final Uint8List provided;
  try {
    provided = Uint8List.fromList(base64Decode(providedBase64));
  } catch (_) {
    return false;
  }
  final expected =
      Hmac(sha256, psk).convert(peerForgotYouCanonical(senderId: senderId));
  if (expected.bytes.length != provided.length) return false;
  var result = 0;
  for (var i = 0; i < provided.length; i++) {
    result |= expected.bytes[i] ^ provided[i];
  }
  return result == 0;
}
