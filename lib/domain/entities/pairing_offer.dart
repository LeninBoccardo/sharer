import 'dart:typed_data';

/// One-time pairing handshake material produced by the initiator. The
/// responder consumes this either by scanning the QR (full payload at
/// once) or — on a device with no camera — by reading the [numericCode]
/// and the [endpoints] off the screen and typing them in.
///
/// The PSK is the long-term shared secret for the pair. Once the /pair
/// handshake completes, both sides store this same PSK keyed by the
/// other device's deviceId, and every subsequent transfer between them
/// is HMAC-SHA256 signed with it (slice 4.2).
class PairingOffer {
  /// Random unique id, also used as the active-offer key on the
  /// initiator's offer registry.
  final String offerId;

  /// 256-bit shared secret for this pair.
  final Uint8List psk;

  /// Six-digit human-typeable code. Bound to this offer so a responder
  /// can't reuse a stale code against a fresh offer.
  final String numericCode;

  /// Candidate `host:port` strings for the initiator's /pair endpoint.
  /// We list every local IPv4 we have because the responder may not be
  /// on the same subnet as our default-route interface (PCs often have a
  /// reachable Wi-Fi IP plus an unreachable Hyper-V/Ethernet IP, and we
  /// can't tell at offer-mint time which the responder will use). The
  /// responder tries each in order and keeps the first that connects.
  final List<String> endpoints;

  final String initiatorId;
  final String initiatorName;

  /// Initiator's long-term Ed25519 public key, raw 32 bytes (slice 4.5).
  /// The responder pins this on pair-completion; the receiver of the
  /// completion request verifies the responder's identity signature
  /// against the responder's own public key included in their response.
  final Uint8List initiatorPublicKey;

  /// Ed25519 signature over the canonical bytes of the offer, signed
  /// with the initiator's long-term private key. Lets the responder
  /// confirm the QR / invite payload was actually produced by the
  /// device claiming to be initiator (the deviceId is unforgeable
  /// because deviceId = SHA-256(publicKey) prefix; this signature ties
  /// the rest of the offer to that key).
  final Uint8List signature;

  /// Slice 5.1: SHA-256 fingerprint (`aa:bb:...`) of the initiator's
  /// TLS server cert. Carried in the QR + signed by the initiator's
  /// Ed25519, so the responder can pin the cert when posting /pair
  /// completion and persist it on the resulting [PairedDevice] for
  /// future hot-path /upload pinning.
  final String initiatorCertFingerprintSha256;

  /// Wall-clock instant after which this offer must be rejected.
  final DateTime expiresAt;

  PairingOffer({
    required this.offerId,
    required this.psk,
    required this.numericCode,
    required this.endpoints,
    required this.initiatorId,
    required this.initiatorName,
    required this.initiatorPublicKey,
    required this.initiatorCertFingerprintSha256,
    required this.signature,
    required this.expiresAt,
  })  : assert(psk.length == 32, 'PSK must be 32 bytes (256 bits)'),
        assert(RegExp(r'^\d{6}$').hasMatch(numericCode),
            'numericCode must be exactly six digits'),
        assert(endpoints.isNotEmpty, 'at least one endpoint is required'),
        assert(initiatorPublicKey.length == 32,
            'initiator publicKey must be 32 bytes'),
        assert(signature.length == 64,
            'Ed25519 signatures are 64 bytes'),
        assert(initiatorCertFingerprintSha256.isNotEmpty,
            'cert fingerprint required since slice 5.1');

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// Canonical bytes covered by the offer's Ed25519 signature. Independent
/// of JSON ordering so the signature stays valid across encoder versions.
///
/// **Slice 5.1 schema bump (v2 → v3):** added
/// `initiatorCertFingerprintSha256`. Old v2 QRs no longer verify and
/// re-pair is required — same back-compat posture as the slice 4.5
/// v1 → v2 bump.
List<int> pairingOfferCanonicalBytes({
  required String offerId,
  required List<int> psk,
  required String numericCode,
  required List<String> endpoints,
  required String initiatorId,
  required String initiatorName,
  required List<int> initiatorPublicKey,
  required String initiatorCertFingerprintSha256,
  required DateTime expiresAt,
}) {
  final parts = <String>[
    'sharer-pair-offer-v3',
    offerId,
    _hex(psk),
    numericCode,
    endpoints.join(','),
    initiatorId,
    initiatorName,
    _hex(initiatorPublicKey),
    initiatorCertFingerprintSha256,
    expiresAt.toUtc().toIso8601String(),
  ];
  return parts.join('\n').codeUnits;
}

String _hex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
