import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entities/pairing_offer.dart';

/// QR payload framing: a versioned ASCII prefix followed by base64-url
/// encoded JSON. The prefix lets a future v3 codec coexist with v2 in
/// the wild and refuse to misparse legacy QRs against a new schema.
///
/// **Schema bump v1 → v2 (slice 4.5):** adds `initiatorPublicKey` (raw
/// Ed25519 public key) and `signature` (Ed25519 over the canonical bytes
/// from `pairingOfferCanonicalBytes`). Old v1 QRs no longer decode —
/// safe because no production pairings exist on the v1 schema.
const String pairingQrPrefix = 'sharer-pair-v2:';

/// Renders a [PairingOffer] as a single string suitable for a QR code.
String encodePairingOffer(PairingOffer offer) {
  final json = jsonEncode({
    'offerId': offer.offerId,
    'psk': base64Encode(offer.psk),
    'code': offer.numericCode,
    'endpoints': offer.endpoints,
    'initiatorId': offer.initiatorId,
    'initiatorName': offer.initiatorName,
    'initiatorPublicKey': base64Encode(offer.initiatorPublicKey),
    'signature': base64Encode(offer.signature),
    'expiresAt': offer.expiresAt.toUtc().toIso8601String(),
  });
  return '$pairingQrPrefix${base64UrlEncode(utf8.encode(json))}';
}

/// Parses a QR-scanned string back into a [PairingOffer]. Returns null
/// for any input that isn't a current-version offer, including empty
/// strings, wrong prefix, malformed base64, malformed JSON, missing
/// fields, or out-of-spec field lengths.
///
/// **Note:** decoding does not verify the offer's signature — that's
/// the responder's job once they have the public key in hand. This
/// function is purely a syntax check.
PairingOffer? decodePairingOffer(String raw) {
  if (!raw.startsWith(pairingQrPrefix)) return null;
  try {
    final body = raw.substring(pairingQrPrefix.length);
    final decoded = utf8.decode(base64Url.decode(body));
    final j = jsonDecode(decoded) as Map<String, dynamic>;
    final psk = Uint8List.fromList(base64Decode(j['psk'] as String));
    if (psk.length != 32) return null;
    final code = j['code'] as String;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return null;
    final endpointsRaw = j['endpoints'];
    final endpoints = endpointsRaw is List
        ? endpointsRaw.map((e) => e as String).toList(growable: false)
        : const <String>[];
    if (endpoints.isEmpty) return null;
    final pub =
        Uint8List.fromList(base64Decode(j['initiatorPublicKey'] as String));
    if (pub.length != 32) return null;
    final sig = Uint8List.fromList(base64Decode(j['signature'] as String));
    if (sig.length != 64) return null;
    return PairingOffer(
      offerId: j['offerId'] as String,
      psk: psk,
      numericCode: code,
      endpoints: endpoints,
      initiatorId: j['initiatorId'] as String,
      initiatorName: j['initiatorName'] as String,
      initiatorPublicKey: pub,
      signature: sig,
      expiresAt: DateTime.parse(j['expiresAt'] as String),
    );
  } catch (_) {
    return null;
  }
}
