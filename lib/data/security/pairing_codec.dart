import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entities/pairing_offer.dart';

/// QR payload framing: a versioned ASCII prefix followed by base64-url
/// encoded JSON. The prefix lets a future v2 codec coexist with v1 in
/// the wild and refuse to misparse legacy QRs against a new schema.
const String pairingQrPrefix = 'sharer-pair-v1:';

/// Renders a [PairingOffer] as a single string suitable for a QR code.
String encodePairingOffer(PairingOffer offer) {
  final json = jsonEncode({
    'offerId': offer.offerId,
    'psk': base64Encode(offer.psk),
    'code': offer.numericCode,
    'endpoint': offer.endpoint,
    'initiatorId': offer.initiatorId,
    'initiatorName': offer.initiatorName,
    'expiresAt': offer.expiresAt.toUtc().toIso8601String(),
  });
  return '$pairingQrPrefix${base64UrlEncode(utf8.encode(json))}';
}

/// Parses a QR-scanned string back into a [PairingOffer]. Returns null
/// for any input that isn't a v1 offer, including empty strings, wrong
/// prefix, malformed base64, malformed JSON, or missing fields. Callers
/// surface a single "not a valid pairing code" error to the user — we
/// don't leak which check failed, since most failures here are user
/// input rather than security-relevant.
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
    return PairingOffer(
      offerId: j['offerId'] as String,
      psk: psk,
      numericCode: code,
      endpoint: j['endpoint'] as String,
      initiatorId: j['initiatorId'] as String,
      initiatorName: j['initiatorName'] as String,
      expiresAt: DateTime.parse(j['expiresAt'] as String),
    );
  } catch (_) {
    return null;
  }
}
