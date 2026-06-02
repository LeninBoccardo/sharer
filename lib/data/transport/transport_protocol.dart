/// Wire-format constants shared by [HttpFileServer] (receive side) and
/// [HttpFileClient] (send side). Keeping them in one place stops the
/// two ends from drifting apart silently.
///
/// Headers chosen instead of multipart so the body can be a single
/// streamed octet-stream — no in-memory buffering of file content.
abstract final class TransportProtocol {
  static const int defaultPort = 8080;

  /// The single transfer route. v1 is **push-only**: bytes always move
  /// via a `POST` here. A `GET /files/:id` *pull* endpoint from the
  /// original protocol sketch is intentionally NOT implemented in v1 —
  /// no v1 surface initiates a pull, so it would be an unused route.
  /// Deferred to v2. See docs/v1/architecture.md
  /// "Pull endpoint (GET /files/:id) — deferred to v2".
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

  /// Slice 5.4: proactive "I'm forgetting you" notification. When a
  /// device taps Forget on a paired peer, before the local removal we
  /// fire a signed POST here so the peer can reciprocally remove the
  /// PairedDevice on their side and surface a "X has unpaired you"
  /// notification. Body shape: `{senderId, timestamp, nonce, signature}`.
  /// The signature is HMAC-SHA256 over
  /// `sharer-peer-forgot-you-v2\n<senderId>\n<timestampMs>\n<nonce>` with
  /// the per-pair PSK. Audit #23: the timestamp + nonce are validated
  /// server-side against the same ~30 s window + nonce buffer `/upload`
  /// uses, so a captured POST can't be replayed. The route is
  /// registered alongside `/upload`, not the pair routes, because the
  /// peer must be reachable here even on networks the receiver hasn't
  /// flagged trusted (the route still verifies HMAC against a known
  /// PairedDevice, so an unknown sender can't trigger arbitrary state
  /// changes).
  static const String peerForgotYouPath = '/peer-forgot-you';

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
  // sender, recipient, filename, size). Audit #30: the recipient's own
  // deviceId is bound into the canonical (the verifier reconstructs it
  // from its local identity, not from a header), so a signature is not
  // replayable against a different recipient sharing the same PSK. See
  // HmacSigner.canonicalString.

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

  /// Slice 5.1: SHA-256 fingerprint of the sender's TLS server cert,
  /// in `aa:bb:...` colon-separated lowercase hex. Sent by the
  /// responder on /pair so the initiator can pin the responder's cert
  /// for future hot-path uploads. Mirrors the
  /// `initiatorCertFingerprintSha256` field that travels in the QR
  /// offer.
  static const String headerCertFingerprint = 'x-sharer-cert-fingerprint';

  /// Slice 5.3: per-transfer 8-byte random id, base64. Used as the HKDF
  /// salt that derives the transferKey from the per-pair PSK, and as
  /// the high 8 bytes of every per-chunk AES-GCM nonce. Travels on
  /// signed `/upload` requests; covered by the HMAC canonical string so
  /// it can't be substituted in flight. Absence on a signed upload
  /// signals an unencrypted body (kept only as a test-convenience path
  /// for plain-HTTP servers).
  static const String headerTransferId = 'x-sharer-transferid';

  /// Audit #1: on an `/upload` rejection the server echoes a coarse
  /// machine-readable reason here so the *sender* can tell a permanent
  /// "you're not paired with me" rejection apart from a transient
  /// signing failure (clock skew, nonce replay, malformed headers).
  /// Only [reasonUnknownSender] should drive the reactive forget path; a
  /// bare 401 with no reason header is transient and must NOT unpair
  /// anyone. Deliberately coarse — it does NOT leak which specific check
  /// failed.
  static const String headerReason = 'x-sharer-reason';

  /// Value of [headerReason] meaning "the senderDeviceId is not in my
  /// paired store" — the peer forgot us. Paired with HTTP 403.
  static const String reasonUnknownSender = 'unknown-sender';

  /// Audit #25: value of [headerReason] meaning the receiver aborted an
  /// in-flight `/upload` because the bytes written reached the receiver's
  /// per-transfer capacity ceiling (a guard against a paired-but-malicious
  /// peer streaming an unbounded body to fill the disk). Paired with HTTP
  /// 507 (Insufficient Storage). This is a resource/capacity rejection,
  /// NOT an authorization one — it must never drive the reactive-forget
  /// path (that is gated on 403 + [reasonUnknownSender]).
  static const String reasonStorageFull = 'storage-full';
}
