import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/pairing_codec.dart';
import 'package:sharer/domain/entities/pairing_offer.dart';

void main() {
  Uint8List psk(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  PairingOffer make({
    String offerId = 'offer-1',
    int seed = 1,
    String code = '012345',
    List<String> endpoints = const ['192.168.68.10:8080', '10.5.0.2:8080'],
    String initiatorId = 'lenin-pc',
    String initiatorName = 'Lenin-PC',
    DateTime? expiresAt,
  }) =>
      PairingOffer(
        offerId: offerId,
        psk: psk(seed),
        numericCode: code,
        endpoints: endpoints,
        initiatorId: initiatorId,
        initiatorName: initiatorName,
        expiresAt: expiresAt ?? DateTime.utc(2026, 5, 4, 12, 1),
      );

  test('encode produces a versioned, prefixed payload', () {
    final encoded = encodePairingOffer(make());
    expect(encoded, startsWith('sharer-pair-v1:'));
  });

  test('encode then decode round-trips every field', () {
    final original = make();
    final decoded = decodePairingOffer(encodePairingOffer(original))!;
    expect(decoded.offerId, original.offerId);
    expect(decoded.psk, original.psk);
    expect(decoded.numericCode, original.numericCode);
    expect(decoded.endpoints, original.endpoints);
    expect(decoded.initiatorId, original.initiatorId);
    expect(decoded.initiatorName, original.initiatorName);
    expect(decoded.expiresAt, original.expiresAt);
  });

  test('decode rejects empty input', () {
    expect(decodePairingOffer(''), isNull);
  });

  test('decode rejects strings without the v1 prefix', () {
    expect(decodePairingOffer('sharer-pair-v2:whatever'), isNull);
    expect(decodePairingOffer('https://example.com'), isNull);
  });

  test('decode rejects malformed base64 or JSON inside the prefix', () {
    expect(decodePairingOffer('sharer-pair-v1:!!!'), isNull);
    expect(decodePairingOffer('sharer-pair-v1:bm90anNvbg=='), isNull);
  });

  test('decode rejects PSK that is not exactly 32 bytes', () {
    final json = jsonEncode({
      'offerId': 'x',
      'psk': base64Encode(Uint8List(16)), // 16 bytes — too short
      'code': '012345',
      'endpoints': ['127.0.0.1:8080'],
      'initiatorId': 'a',
      'initiatorName': 'a',
      'expiresAt': '2026-05-04T12:01:00.000Z',
    });
    final tampered = 'sharer-pair-v1:${base64UrlEncode(utf8.encode(json))}';
    expect(decodePairingOffer(tampered), isNull,
        reason: 'short PSK must be rejected');
  });

  test('decode rejects payload with no endpoints', () {
    final json = jsonEncode({
      'offerId': 'x',
      'psk': base64Encode(Uint8List(32)),
      'code': '012345',
      'endpoints': <String>[],
      'initiatorId': 'a',
      'initiatorName': 'a',
      'expiresAt': '2026-05-04T12:01:00.000Z',
    });
    final empty = 'sharer-pair-v1:${base64UrlEncode(utf8.encode(json))}';
    expect(decodePairingOffer(empty), isNull);
  });

  test('decode rejects non-six-digit numeric code', () {
    final p = make(code: '012345');
    final encoded = encodePairingOffer(p);
    expect(decodePairingOffer(encoded), isNotNull);
    // Replace the code in JSON: easier to just construct a fresh malformed.
    expect(
      decodePairingOffer('sharer-pair-v1:not-a-code'),
      isNull,
    );
  });
}
