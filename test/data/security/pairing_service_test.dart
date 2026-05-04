import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pairing_service.dart';
import 'package:sharer/domain/entities/pairing_offer.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

void main() {
  late FakeSecureKeyValueStore secure;
  late PairedDevicesStore paired;
  late StaticIdentityRepo identity;
  late DateTime now;
  late PairingService service;

  setUp(() {
    secure = FakeSecureKeyValueStore();
    paired = PairedDevicesStore(secure);
    identity = StaticIdentityRepo(id: 'lenin-pc', name: 'Lenin-PC');
    now = DateTime.utc(2026, 5, 4, 12);
    service = PairingService(
      paired,
      identity,
      random: Random(0),
      now: () => now,
    );
  });

  tearDown(() async {
    await service.dispose();
    await paired.dispose();
  });

  Future<PairingOffer> mintOffer({Duration? ttl}) async {
    return service.createOffer(
      endpoint: '192.168.68.10:8080',
      ttl: ttl ?? const Duration(seconds: 60),
    );
  }

  String signCompletion({
    required PairingOffer offer,
    required String responderId,
    String? overrideCode,
  }) {
    final canonical = pairingCanonicalString(
      offerId: offer.offerId,
      responderId: responderId,
      numericCode: overrideCode ?? offer.numericCode,
    );
    final mac = Hmac(sha256, offer.psk).convert(utf8.encode(canonical));
    return base64Encode(mac.bytes);
  }

  test('createOffer mints a 6-digit code, 32-byte PSK, and stable identity',
      () async {
    final offer = await mintOffer();
    expect(offer.numericCode, matches(RegExp(r'^\d{6}$')));
    expect(offer.psk, hasLength(32));
    expect(offer.initiatorId, 'lenin-pc');
    expect(offer.initiatorName, 'Lenin-PC');
    expect(offer.endpoint, '192.168.68.10:8080');
    expect(offer.expiresAt, now.add(const Duration(seconds: 60)));
  });

  test('two consecutive offers produce different ids, codes, and PSKs',
      () async {
    final a = await mintOffer();
    final b = await mintOffer();
    expect(a.offerId, isNot(equals(b.offerId)));
    expect(a.numericCode, isNot(equals(b.numericCode)));
    expect(a.psk, isNot(equals(b.psk)));
  });

  test('completePair stores the responder, removes the offer, emits completion',
      () async {
    final offer = await mintOffer();
    final completions = <String>[];
    final sub =
        service.completions.listen((d) => completions.add(d.deviceId));

    final result = await service.completePair(
      offerId: offer.offerId,
      numericCode: offer.numericCode,
      responderId: 'realme',
      responderName: 'Realme',
      signature: signCompletion(offer: offer, responderId: 'realme'),
    );

    expect(result, isNotNull);
    expect(result!.deviceId, 'realme');
    expect(result.psk, offer.psk);
    expect((await paired.getAll()).single.deviceId, 'realme');

    await pumpEventQueue();
    expect(completions, ['realme']);
    await sub.cancel();
  });

  test('completePair is single-use — second call with same offerId rejects',
      () async {
    final offer = await mintOffer();
    final sig = signCompletion(offer: offer, responderId: 'realme');
    final first = await service.completePair(
      offerId: offer.offerId,
      numericCode: offer.numericCode,
      responderId: 'realme',
      responderName: 'Realme',
      signature: sig,
    );
    expect(first, isNotNull);

    final second = await service.completePair(
      offerId: offer.offerId,
      numericCode: offer.numericCode,
      responderId: 'realme',
      responderName: 'Realme',
      signature: sig,
    );
    expect(second, isNull);
  });

  test('completePair rejects unknown offerId', () async {
    expect(
      await service.completePair(
        offerId: 'nope',
        numericCode: '000000',
        responderId: 'realme',
        responderName: 'Realme',
        signature: 'AAAA',
      ),
      isNull,
    );
  });

  test('completePair rejects after the TTL has elapsed', () async {
    final offer = await mintOffer(ttl: const Duration(seconds: 60));
    now = now.add(const Duration(seconds: 120));
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: 'realme',
        responderName: 'Realme',
        signature: signCompletion(offer: offer, responderId: 'realme'),
      ),
      isNull,
    );
  });

  test('completePair rejects mismatched numeric code', () async {
    final offer = await mintOffer();
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: '999999',
        responderId: 'realme',
        responderName: 'Realme',
        signature: signCompletion(offer: offer, responderId: 'realme'),
      ),
      isNull,
    );
  });

  test('completePair rejects when canonical responderId is forged', () async {
    final offer = await mintOffer();
    // Sign for "realme" but claim to be "phantom".
    final sig = signCompletion(offer: offer, responderId: 'realme');
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: 'phantom',
        responderName: 'Phantom',
        signature: sig,
      ),
      isNull,
    );
  });

  test('completePair rejects malformed (non-base64) signature', () async {
    final offer = await mintOffer();
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: 'realme',
        responderName: 'Realme',
        signature: '!!!not-base64!!!',
      ),
      isNull,
    );
  });

  test('cancelOffer removes an active offer', () async {
    final offer = await mintOffer();
    service.cancelOffer(offer.offerId);
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: 'realme',
        responderName: 'Realme',
        signature: signCompletion(offer: offer, responderId: 'realme'),
      ),
      isNull,
    );
  });

  test('acceptOffer stores the initiator on the responder side', () async {
    final offer = await mintOffer();
    final stored = await service.acceptOffer(offer);
    expect(stored.deviceId, offer.initiatorId);
    expect(stored.displayName, offer.initiatorName);
    expect(stored.psk, offer.psk);
    expect((await paired.getAll()).single.deviceId, offer.initiatorId);
  });
}
