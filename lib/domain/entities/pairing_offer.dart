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

  /// Wall-clock instant after which this offer must be rejected.
  final DateTime expiresAt;

  PairingOffer({
    required this.offerId,
    required this.psk,
    required this.numericCode,
    required this.endpoints,
    required this.initiatorId,
    required this.initiatorName,
    required this.expiresAt,
  })  : assert(psk.length == 32, 'PSK must be 32 bytes (256 bits)'),
        assert(RegExp(r'^\d{6}$').hasMatch(numericCode),
            'numericCode must be exactly six digits'),
        assert(endpoints.isNotEmpty, 'at least one endpoint is required');

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}
