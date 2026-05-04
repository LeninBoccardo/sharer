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
  Future<PairingOffer> createOffer({
    required String endpoint,
    Duration ttl = const Duration(seconds: 60),
  }) async {
    _purgeExpired();
    final identity = await _identity.get();
    final offer = PairingOffer(
      offerId: _uuid.v4(),
      psk: _randomBytes(32),
      numericCode: _randomNumericCode(),
      endpoint: endpoint,
      initiatorId: identity.id,
      initiatorName: identity.name,
      expiresAt: _now().add(ttl),
    );
    _activeOffers[offer.offerId] = offer;
    _log('createOffer id=${offer.offerId} code=${offer.numericCode} '
        'endpoint=$endpoint expiresAt=${offer.expiresAt.toIso8601String()}');
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
  Future<PairedDevice?> completePair({
    required String offerId,
    required String numericCode,
    required String responderId,
    required String responderName,
    required String signature,
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
    final canonical = pairingCanonicalString(
      offerId: offerId,
      responderId: responderId,
      numericCode: numericCode,
    );
    final expected = Hmac(sha256, offer.psk).convert(utf8.encode(canonical));
    final provided = _safeBase64Decode(signature);
    if (provided == null) {
      _log('completePair reject: malformed signature id=$offerId');
      return null;
    }
    if (!_constantTimeEquals(expected.bytes, provided)) {
      _log('completePair reject: signature mismatch id=$offerId');
      return null;
    }
    final paired = PairedDevice(
      deviceId: responderId,
      displayName: responderName,
      psk: offer.psk,
      pairedAt: _now(),
    );
    await _paired.add(paired);
    _activeOffers.remove(offerId);
    _completions.add(paired);
    _log('completePair OK id=$offerId responder=$responderId');
    return paired;
  }

  /// Responder-side. Stores the initiator as paired once the HTTP POST
  /// to the offer's endpoint has come back 200.
  Future<PairedDevice> acceptOffer(PairingOffer offer) async {
    final paired = PairedDevice(
      deviceId: offer.initiatorId,
      displayName: offer.initiatorName,
      psk: offer.psk,
      pairedAt: _now(),
    );
    await _paired.add(paired);
    _log('acceptOffer stored initiator=${offer.initiatorId}');
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
