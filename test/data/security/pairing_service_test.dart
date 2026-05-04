import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/security/long_term_signer.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/security/pairing_service.dart';
import 'package:sharer/domain/entities/pairing_offer.dart';

import '../../fakes/fake_secure_key_value_store.dart';
import '../../fakes/static_identity_repo.dart';

void main() {
  late FakeSecureKeyValueStore secure;
  late PairedDevicesStore paired;
  late StaticIdentityRepo initiatorIdentity;
  late StaticIdentityRepo responderIdentity;
  late DateTime now;
  late PairingService service;

  setUp(() async {
    secure = FakeSecureKeyValueStore();
    paired = PairedDevicesStore(secure);
    initiatorIdentity =
        await StaticIdentityRepo.create(seed: 1, name: 'Lenin-PC');
    responderIdentity =
        await StaticIdentityRepo.create(seed: 2, name: 'Realme');
    now = DateTime.utc(2026, 5, 4, 12);
    service = PairingService(
      paired,
      initiatorIdentity,
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
      endpoints: const ['192.168.68.10:8080'],
      ttl: ttl ?? const Duration(seconds: 60),
    );
  }

  /// Returns (pskHmacSig, ed25519IdentitySig) for the canonical pair-
  /// completion message. By default the responder signs as themselves;
  /// pass [signWithIdentity] to use a different identity (e.g. to test
  /// imposter rejection).
  Future<({String psk, String identity})> signCompletion({
    required PairingOffer offer,
    required String responderId,
    String? overrideCode,
    StaticIdentityRepo? signWithIdentity,
  }) async {
    final canonical = pairingCanonicalString(
      offerId: offer.offerId,
      responderId: responderId,
      numericCode: overrideCode ?? offer.numericCode,
    );
    final canonicalBytes = utf8.encode(canonical);
    final mac = Hmac(sha256, offer.psk).convert(canonicalBytes);
    final repo = signWithIdentity ?? responderIdentity;
    final ed = await repo.sign(canonicalBytes);
    return (
      psk: base64Encode(mac.bytes),
      identity: base64Encode(ed),
    );
  }

  test(
      'createOffer mints a 6-digit code, 32-byte PSK, signs with initiator '
      'long-term key, embeds initiatorPublicKey', () async {
    final offer = await mintOffer();
    expect(offer.numericCode, matches(RegExp(r'^\d{6}$')));
    expect(offer.psk, hasLength(32));
    expect(offer.initiatorId, initiatorIdentity.id);
    expect(offer.initiatorName, 'Lenin-PC');
    expect(offer.endpoints, ['192.168.68.10:8080']);
    expect(offer.expiresAt, now.add(const Duration(seconds: 60)));
    expect(offer.initiatorPublicKey, initiatorIdentity.publicKey);
    expect(offer.signature, hasLength(64));
    // Signature actually verifies against the initiator's public key.
    final canonical = pairingOfferCanonicalBytes(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: offer.endpoints,
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      expiresAt: offer.expiresAt,
    );
    final ok = await LongTermSigner.verify(
      message: canonical,
      signature: offer.signature,
      publicKey: offer.initiatorPublicKey,
    );
    expect(ok, isTrue);
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

    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);
    final result = await service.completePair(
      offerId: offer.offerId,
      numericCode: offer.numericCode,
      responderId: responderIdentity.id,
      responderName: 'Realme',
      responderPublicKey: responderIdentity.publicKey,
      signature: sig.psk,
      identitySignature: sig.identity,
    );

    expect(result, isNotNull);
    expect(result!.deviceId, responderIdentity.id);
    expect(result.psk, offer.psk);
    expect(result.publicKey, responderIdentity.publicKey);
    final stored = (await paired.getAll()).single;
    expect(stored.deviceId, responderIdentity.id);
    expect(stored.publicKey, responderIdentity.publicKey);

    await pumpEventQueue();
    expect(completions, [responderIdentity.id]);
    await sub.cancel();
  });

  test('completePair is single-use — second call with same offerId rejects',
      () async {
    final offer = await mintOffer();
    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);

    Future<dynamic> attempt() => service.completePair(
          offerId: offer.offerId,
          numericCode: offer.numericCode,
          responderId: responderIdentity.id,
          responderName: 'Realme',
          responderPublicKey: responderIdentity.publicKey,
          signature: sig.psk,
          identitySignature: sig.identity,
        );

    expect(await attempt(), isNotNull);
    expect(await attempt(), isNull);
  });

  test('completePair rejects unknown offerId', () async {
    expect(
      await service.completePair(
        offerId: 'nope',
        numericCode: '000000',
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: 'AAAA',
        identitySignature: base64Encode(Uint8List(64)),
      ),
      isNull,
    );
  });

  test('completePair rejects after the TTL has elapsed', () async {
    final offer = await mintOffer(ttl: const Duration(seconds: 60));
    now = now.add(const Duration(seconds: 120));
    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: sig.psk,
        identitySignature: sig.identity,
      ),
      isNull,
    );
  });

  test('completePair rejects mismatched numeric code', () async {
    final offer = await mintOffer();
    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: '999999',
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: sig.psk,
        identitySignature: sig.identity,
      ),
      isNull,
    );
  });

  test('completePair rejects when claimed responderId does not hash from '
      'the supplied publicKey', () async {
    final offer = await mintOffer();
    // Sign correctly as ourselves, but claim a forged responderId.
    final sig = await signCompletion(offer: offer, responderId: 'phantom');
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: 'phantom', // doesn't hash from responderIdentity.publicKey
        responderName: 'Phantom',
        responderPublicKey: responderIdentity.publicKey,
        signature: sig.psk,
        identitySignature: sig.identity,
      ),
      isNull,
    );
  });

  test('completePair rejects when identity signature was made with a '
      'different long-term key', () async {
    final offer = await mintOffer();
    // Sign Ed25519 as a third party (some other identity), but claim
    // responderIdentity's deviceId + publicKey.
    final imposter = await StaticIdentityRepo.create(seed: 99, name: 'Mal');
    final sig = await signCompletion(
      offer: offer,
      responderId: responderIdentity.id,
      signWithIdentity: imposter,
    );
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: sig.psk, // PSK HMAC works (anyone with PSK can produce)
        identitySignature: sig.identity, // signed by wrong key → rejected
      ),
      isNull,
    );
  });

  test('completePair rejects malformed (non-base64) PSK signature', () async {
    final offer = await mintOffer();
    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: '!!!not-base64!!!',
        identitySignature: sig.identity,
      ),
      isNull,
    );
  });

  test('cancelOffer removes an active offer', () async {
    final offer = await mintOffer();
    service.cancelOffer(offer.offerId);
    final sig = await signCompletion(
        offer: offer, responderId: responderIdentity.id);
    expect(
      await service.completePair(
        offerId: offer.offerId,
        numericCode: offer.numericCode,
        responderId: responderIdentity.id,
        responderName: 'Realme',
        responderPublicKey: responderIdentity.publicKey,
        signature: sig.psk,
        identitySignature: sig.identity,
      ),
      isNull,
    );
  });

  test('acceptOffer stores the initiator on the responder side', () async {
    final offer = await mintOffer();
    final stored = await service.acceptOffer(offer);
    expect(stored, isNotNull);
    expect(stored!.deviceId, offer.initiatorId);
    expect(stored.displayName, offer.initiatorName);
    expect(stored.psk, offer.psk);
    expect(stored.publicKey, offer.initiatorPublicKey);
    expect((await paired.getAll()).single.deviceId, offer.initiatorId);
  });

  test('acceptOffer rejects when offer signature does not verify', () async {
    final offer = await mintOffer();
    // Tamper the signature with a fresh 64-byte zero buffer.
    final tampered = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: offer.endpoints,
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      signature: Uint8List(64),
      expiresAt: offer.expiresAt,
    );
    expect(await service.acceptOffer(tampered), isNull);
    expect(await paired.getAll(), isEmpty);
  });

  test('acceptOffer rejects when initiatorId does not hash from publicKey',
      () async {
    final offer = await mintOffer();
    final tampered = PairingOffer(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: offer.endpoints,
      initiatorId: 'forged-id', // mismatch
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      signature: offer.signature,
      expiresAt: offer.expiresAt,
    );
    expect(await service.acceptOffer(tampered), isNull);
  });
}
