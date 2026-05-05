import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/paired_device.dart';
import '../../domain/entities/pairing_offer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import 'long_term_signer.dart';

/// Canonical input to the /pair completion HMAC. Different from the
/// transfer canonical (no timestamp / nonce / filename) because each
/// offer is single-use and short-lived; the offer's TTL plus the
/// remove-on-success behavior bound the replay window.
String pairingCanonicalString({
  required String offerId,
  required String responderId,
  required String numericCode,
}) {
  return 'POST\n/pair\n$offerId\n$responderId\n$numericCode';
}

/// Coordinator for the pairing handshake on both sides of the wire.
///
/// On the **initiator**, [createOffer] mints a fresh offer, [completePair]
/// is called from the /pair handler to validate and register the
/// responder, and [completions] surfaces successful completions to the
/// UI (so the "Show code" screen can flip to "Paired with [name]").
///
/// On the **responder**, [acceptOffer] is called once the network POST
/// has come back 200 — it stores the initiator as paired using the same
/// PSK both sides now share.
class PairingService {
  static const _logName = 'sharer.security.pairing';

  final PairedDevicesRepository _paired;
  final DeviceIdentityRepository _identity;
  final Random _random;
  final DateTime Function() _now;
  final Uuid _uuid;

  final Map<String, PairingOffer> _activeOffers = {};
  final _completions = StreamController<PairedDevice>.broadcast();

  PairingService(
    this._paired,
    this._identity, {
    Random? random,
    DateTime Function()? now,
    Uuid? uuid,
  })  : _random = random ?? Random.secure(),
        _now = now ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  /// Successful completions from the /pair endpoint, in arrival order.
  /// The "Show code" screen subscribes to this so it can dismiss itself
  /// once the responder has confirmed.
  Stream<PairedDevice> get completions => _completions.stream;

  /// Creates a fresh offer and registers it as active. Caller renders
  /// the offer (QR + numeric code) and listens on [completions] for the
  /// responder's POST.
  ///
  /// [localCertFingerprintSha256] is the local TLS server's cert
  /// fingerprint (slice 5.1) — embedded in the QR + signed by the
  /// initiator's Ed25519 so the responder can pin it when posting
  /// /pair completion and persist it on the resulting [PairedDevice].
  Future<PairingOffer> createOffer({
    required List<String> endpoints,
    required String localCertFingerprintSha256,
    Duration ttl = const Duration(seconds: 60),
  }) async {
    _purgeExpired();
    if (endpoints.isEmpty) {
      throw ArgumentError.value(
          endpoints, 'endpoints', 'must contain at least one host:port');
    }
    final identity = await _identity.get();
    final offerId = _uuid.v4();
    final psk = _randomBytes(32);
    final code = _randomNumericCode();
    final expiresAt = _now().add(ttl);
    final canonical = pairingOfferCanonicalBytes(
      offerId: offerId,
      psk: psk,
      numericCode: code,
      endpoints: endpoints,
      initiatorId: identity.id,
      initiatorName: identity.name,
      initiatorPublicKey: identity.publicKey,
      initiatorCertFingerprintSha256: localCertFingerprintSha256,
      expiresAt: expiresAt,
    );
    final sigBytes = await _identity.sign(canonical);
    final offer = PairingOffer(
      offerId: offerId,
      psk: psk,
      numericCode: code,
      endpoints: List.unmodifiable(endpoints),
      initiatorId: identity.id,
      initiatorName: identity.name,
      initiatorPublicKey: identity.publicKey,
      initiatorCertFingerprintSha256: localCertFingerprintSha256,
      signature: Uint8List.fromList(sigBytes),
      expiresAt: expiresAt,
    );
    _activeOffers[offer.offerId] = offer;
    _log('createOffer id=${offer.offerId} code=${offer.numericCode} '
        'endpoints=$endpoints expiresAt=${offer.expiresAt.toIso8601String()}');
    return offer;
  }

  /// Drops an offer from the registry without saving anything. Called
  /// when the user backs out of the "Show code" screen.
  void cancelOffer(String offerId) {
    if (_activeOffers.remove(offerId) != null) {
      _log('cancelOffer id=$offerId');
    }
  }

  /// Initiator-side validation. Returns the [PairedDevice] that was
  /// stored on success, or null on any failure (caller returns 401).
  /// Per spec we don't leak which check failed — log the reason locally
  /// for debugging but the caller's wire response is a bare 401.
  ///
  /// The responder must prove two things:
  ///   1. They have the offer's ephemeral PSK (HMAC over the canonical
  ///      string). This is cheap and ties the request to *this* offer.
  ///   2. They are the device that owns [responderPublicKey] (Ed25519
  ///      identity signature). Plus their claimed [responderId] hashes
  ///      from that key — slice 4.5 makes deviceId unforgeable.
  Future<PairedDevice?> completePair({
    required String offerId,
    required String numericCode,
    required String responderId,
    required String responderName,
    required Uint8List responderPublicKey,
    required String signature,
    required String identitySignature,
    String? responderCertFingerprint,
  }) async {
    _purgeExpired();
    final offer = _activeOffers[offerId];
    if (offer == null) {
      _log('completePair reject: unknown offer id=$offerId');
      return null;
    }
    if (offer.isExpired(_now())) {
      _activeOffers.remove(offerId);
      _log('completePair reject: expired offer id=$offerId');
      return null;
    }
    if (offer.numericCode != numericCode) {
      _log('completePair reject: code mismatch id=$offerId');
      return null;
    }
    if (responderPublicKey.length != 32) {
      _log('completePair reject: bad publicKey length id=$offerId');
      return null;
    }
    final claimedFingerprint =
        LongTermSigner.fingerprintOf(responderPublicKey);
    if (claimedFingerprint != responderId) {
      _log('completePair reject: deviceId/publicKey mismatch id=$offerId '
          '(claimed=$responderId derived=$claimedFingerprint)');
      return null;
    }
    final canonical = pairingCanonicalString(
      offerId: offerId,
      responderId: responderId,
      numericCode: numericCode,
    );
    final canonicalBytes = utf8.encode(canonical);
    // 1. PSK HMAC.
    final expected = Hmac(sha256, offer.psk).convert(canonicalBytes);
    final pskSig = _safeBase64Decode(signature);
    if (pskSig == null) {
      _log('completePair reject: malformed PSK signature id=$offerId');
      return null;
    }
    if (!_constantTimeEquals(expected.bytes, pskSig)) {
      _log('completePair reject: PSK signature mismatch id=$offerId');
      return null;
    }
    // 2. Ed25519 identity signature with the responder's public key.
    final identitySigBytes = _safeBase64Decode(identitySignature);
    if (identitySigBytes == null || identitySigBytes.length != 64) {
      _log('completePair reject: malformed identity signature id=$offerId');
      return null;
    }
    final identityOk = await LongTermSigner.verify(
      message: canonicalBytes,
      signature: identitySigBytes,
      publicKey: responderPublicKey,
    );
    if (!identityOk) {
      _log('completePair reject: identity signature mismatch id=$offerId');
      return null;
    }
    final paired = PairedDevice(
      deviceId: responderId,
      displayName: responderName,
      psk: offer.psk,
      publicKey: responderPublicKey,
      certFingerprint: responderCertFingerprint,
      pairedAt: _now(),
    );
    await _paired.add(paired);
    _activeOffers.remove(offerId);
    _completions.add(paired);
    _log('completePair OK id=$offerId responder=$responderId '
        'certFingerprint=${responderCertFingerprint ?? "<unset>"}');
    return paired;
  }

  /// Pure check — verifies the offer's claimed deviceId hashes from the
  /// embedded publicKey AND the Ed25519 signature is valid. Side-effect
  /// free; safe for the responder to call before sending anything over
  /// the wire so a tampered offer is rejected without leaking signed
  /// proofs about ourselves.
  Future<bool> validateOffer(PairingOffer offer) async {
    if (LongTermSigner.fingerprintOf(offer.initiatorPublicKey) !=
        offer.initiatorId) {
      _log('validateOffer reject: initiator deviceId/publicKey mismatch');
      return false;
    }
    final canonical = pairingOfferCanonicalBytes(
      offerId: offer.offerId,
      psk: offer.psk,
      numericCode: offer.numericCode,
      endpoints: offer.endpoints,
      initiatorId: offer.initiatorId,
      initiatorName: offer.initiatorName,
      initiatorPublicKey: offer.initiatorPublicKey,
      initiatorCertFingerprintSha256: offer.initiatorCertFingerprintSha256,
      expiresAt: offer.expiresAt,
    );
    final ok = await LongTermSigner.verify(
      message: canonical,
      signature: offer.signature,
      publicKey: offer.initiatorPublicKey,
    );
    if (!ok) {
      _log('validateOffer reject: offer signature mismatch');
      return false;
    }
    return true;
  }

  /// Responder-side. Calls [validateOffer] and on success stores the
  /// initiator as paired. Returns null if validation fails (caller
  /// surfaces a single "pairing rejected" error) or the stored
  /// [PairedDevice] on success. The initiator's TLS cert fingerprint
  /// (carried in the offer) is pinned on the resulting [PairedDevice]
  /// so future hot-path /upload requests to the initiator pin against
  /// it.
  Future<PairedDevice?> acceptOffer(PairingOffer offer) async {
    if (!await validateOffer(offer)) return null;
    final paired = PairedDevice(
      deviceId: offer.initiatorId,
      displayName: offer.initiatorName,
      psk: offer.psk,
      publicKey: offer.initiatorPublicKey,
      certFingerprint: offer.initiatorCertFingerprintSha256,
      pairedAt: _now(),
    );
    await _paired.add(paired);
    _log('acceptOffer stored initiator=${offer.initiatorId} '
        'certFingerprint=${offer.initiatorCertFingerprintSha256}');
    return paired;
  }

  Future<void> dispose() async {
    await _completions.close();
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  String _randomNumericCode() {
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buf.write(_random.nextInt(10));
    }
    return buf.toString();
  }

  void _purgeExpired() {
    final n = _now();
    _activeOffers.removeWhere((_, o) => o.isExpired(n));
  }

  static Uint8List? _safeBase64Decode(String s) {
    try {
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
