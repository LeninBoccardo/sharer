/// Wire-format constants shared by [HttpFileServer] (receive side) and
/// [HttpFileClient] (send side). Keeping them in one place stops the
/// two ends from drifting apart silently.
///
/// Headers chosen instead of multipart so the body can be a single
/// streamed octet-stream — no in-memory buffering of file content.
abstract final class TransportProtocol {
  static const int defaultPort = 8080;
  static const String uploadPath = '/upload';

  /// One-time pairing-completion endpoint (slice 4.3). The initiator's
  /// HTTP server accepts a single signed POST here from the responder
  /// after a QR scan or numeric-code entry, and uses it to register the
  /// responder as a paired peer.
  static const String pairPath = '/pair';

  /// Slice 4.6: LAN pair-invite — first leg of the authenticated DH
  /// handshake. Initiator POSTs an Ed25519-signed JSON body containing
  /// their ephemeral X25519 public key; responder validates, generates
  /// their own ephemeral, derives the shared PSK, and replies with the
  /// signed response payload. Both sides then display the per-pair
  /// fingerprint for the user to confirm. Only registered on trusted
  /// networks per docs/v1/security.md §6.
  static const String pairInvitePath = '/pair-invite';

  /// Slice 4.6: pair-finalize — second leg. After the user taps
  /// Matches / Doesn't match on the fingerprint modal, both sides POST
  /// their verdict here. The pair is committed only when both verdicts
  /// are "match". HMAC'd with the in-flight PSK so a passive observer
  /// cannot inject a verdict.
  static const String pairFinalizePath = '/pair-finalize';

  /// URL-encoded filename. Decoded with [Uri.decodeComponent] on the
  /// server. Required.
  static const String headerFileName = 'x-sharer-filename';

  /// Total payload size in bytes. Used by the server only for the
  /// progress total. Receiver streams until the body ends regardless.
  static const String headerFileSize = 'x-sharer-filesize';

  /// Sender's stable device id (UUID). On signed requests this is also
  /// the lookup key for the receiver's PSK.
  static const String headerDeviceId = 'x-sharer-deviceid';

  /// URL-encoded human-readable device name from the sender.
  static const String headerDeviceName = 'x-sharer-devicename';

  // ---- Slice 4.2: HMAC authentication. ----
  // All three are required as a set; if any is present, the others must
  // be too. Signed values cover the request manifest (method, path,
  // sender, filename, size). See HmacSigner.canonicalString.

  /// Sender's clock at request time, in unix milliseconds (UTC).
  static const String headerTimestamp = 'x-sharer-timestamp';

  /// Random 128-bit nonce, base64-encoded. Receiver dedupes within the
  /// nonce TTL window to defeat replay.
  static const String headerNonce = 'x-sharer-nonce';

  /// Base64 HMAC-SHA256 over the canonical string built from the other
  /// fields, using the receiver's per-pair PSK. Reused by /pair where
  /// the canonical string is `POST\n/pair\n<offerId>\n<responderId>\n<code>`
  /// signed with the offer's ephemeral PSK.
  static const String headerSignature = 'x-sharer-sig';

  // ---- Slice 4.3: pairing-completion headers, used only on /pair. ----

  /// The offer id from the QR / typed code. Identifies which active
  /// offer the initiator should validate against.
  static const String headerPairOfferId = 'x-sharer-pair-offer-id';

  /// The 6-digit numeric code from the same QR. Bound to the offer id;
  /// rejected if it doesn't match the offer's stored code.
  static const String headerPairCode = 'x-sharer-pair-code';

  /// Slice 4.5: responder's long-term Ed25519 public key, base64. The
  /// receiver pins this alongside the per-pair PSK, and verifies the
  /// claimed [headerDeviceId] hashes from this key before storing.
  static const String headerPublicKey = 'x-sharer-publickey';

  /// Slice 4.5: Ed25519 signature over the same canonical string the
  /// PSK HMAC covers, signed with the responder's long-term private
  /// key. Proves "I am the device that owns [headerPublicKey]" alongside
  /// the PSK proof of "I have the offer's ephemeral key."
  static const String headerIdentitySignature = 'x-sharer-identity-sig';
}
