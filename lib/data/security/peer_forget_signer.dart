import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Slice 5.4 — canonical input for `/peer-forgot-you` HMAC.
///
/// Audit #23: the v1 canonical was `verb\n<senderId>` only — no timestamp,
/// no nonce — so the signature was valid forever and fully replayable. A
/// passive observer (or a once-paired-then-removed peer) could capture one
/// POST and replay it to force the victim to drop the pairing + spam a
/// notification. The v2 canonical binds a timestamp and a per-request
/// nonce, validated server-side against the same ~30 s window + nonce
/// buffer the /upload path uses (see `HmacVerifier.checkFreshness`).
///
/// The wire body shape is now:
///
/// ```json
/// { "senderId": "<deviceId>", "timestamp": "<unix-ms>",
///   "nonce": "<base64>", "signature": "<base64 HMAC>" }
/// ```
///
/// Clean breaking change (audit decision): no v1 fallback. Both devices
/// update together; a v1 sender is simply rejected as a bad signature.

/// A signed peer-forgot-you token: the three freshness/auth fields that
/// travel on the wire alongside `senderId`. Mirrors [SignedRequestHeaders]
/// in shape so the call sites read the same.
class SignedForgetToken {
  const SignedForgetToken({
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });

  /// Sender's clock at sign time, unix ms (UTC), as a string.
  final String timestamp;

  /// Base64 random nonce, deduped server-side within the nonce TTL.
  final String nonce;

  /// Base64 HMAC-SHA256 over the v2 canonical.
  final String signature;
}

const String _verbForgotYou = 'sharer-peer-forgot-you-v2';

List<int> peerForgotYouCanonical({
  required String senderId,
  required int timestampMs,
  required String nonce,
}) {
  return utf8.encode([
    _verbForgotYou,
    senderId,
    timestampMs.toString(),
    nonce,
  ].join('\n'));
}

/// Returns the [SignedForgetToken] for a peer-forgot-you request signed by
/// [psk]. The caller supplies [timestampMs] (its current UTC clock) and a
/// fresh random [nonce]; both travel on the wire so the receiver can
/// validate freshness + dedupe replays.
SignedForgetToken signPeerForgotYou({
  required Uint8List psk,
  required String senderId,
  required int timestampMs,
  required String nonce,
}) {
  final mac = Hmac(sha256, psk).convert(peerForgotYouCanonical(
    senderId: senderId,
    timestampMs: timestampMs,
    nonce: nonce,
  ));
  return SignedForgetToken(
    timestamp: timestampMs.toString(),
    nonce: nonce,
    signature: base64Encode(mac.bytes),
  );
}

/// Constant-time comparison of an inbound base64 signature against the
/// expected HMAC for the v2 canonical. Returns true on a match.
///
/// This checks ONLY authenticity (the signature binds senderId + timestamp
/// + nonce to the PSK). Freshness — that the timestamp is in window and the
/// nonce hasn't been seen — is enforced separately by
/// [HmacVerifier.checkFreshness], so a valid-but-stale or replayed token is
/// rejected even though its signature verifies.
bool verifyPeerForgotYouSignature({
  required Uint8List psk,
  required String senderId,
  required int timestampMs,
  required String nonce,
  required String providedBase64,
}) {
  final Uint8List provided;
  try {
    provided = Uint8List.fromList(base64Decode(providedBase64));
  } catch (_) {
    return false;
  }
  final expected = Hmac(sha256, psk).convert(peerForgotYouCanonical(
    senderId: senderId,
    timestampMs: timestampMs,
    nonce: nonce,
  ));
  if (expected.bytes.length != provided.length) return false;
  var result = 0;
  for (var i = 0; i < provided.length; i++) {
    result |= expected.bytes[i] ^ provided[i];
  }
  return result == 0;
}
