import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/pairing_offer.dart';
import '../transport/transport_protocol.dart';
import 'pairing_service.dart';

/// Outcome of the responder-side /pair POST.
enum PairingPostResult {
  ok,
  rejected,
  networkError,
  malformedEndpoint,
}

/// Responder-side HTTP client for the /pair handshake. Separate from
/// [HttpFileClient] so the pairing path doesn't drag the upload code
/// down with it (and so we can swap the transport for TLS in slice 5
/// without touching transfers).
class PairingClient {
  static const _logName = 'sharer.security.pairing.client';

  final HttpClient _http;

  PairingClient([HttpClient? http]) : _http = http ?? HttpClient();

  /// POSTs the completion handshake to the offer's endpoint. On 200 the
  /// caller stores the initiator as paired (via PairingService.acceptOffer).
  Future<PairingPostResult> postCompletion({
    required PairingOffer offer,
    required DeviceIdentity responder,
  }) async {
    final colon = offer.endpoint.lastIndexOf(':');
    if (colon < 0 || colon == offer.endpoint.length - 1) {
      _log('malformed endpoint: ${offer.endpoint}');
      return PairingPostResult.malformedEndpoint;
    }
    final host = offer.endpoint.substring(0, colon);
    final port = int.tryParse(offer.endpoint.substring(colon + 1));
    if (port == null) {
      _log('malformed endpoint port: ${offer.endpoint}');
      return PairingPostResult.malformedEndpoint;
    }

    final canonical = pairingCanonicalString(
      offerId: offer.offerId,
      responderId: responder.id,
      numericCode: offer.numericCode,
    );
    final mac = Hmac(sha256, offer.psk).convert(utf8.encode(canonical));
    final sig = base64Encode(mac.bytes);
    final uri =
        Uri.parse('http://$host:$port${TransportProtocol.pairPath}');
    _log('POST $uri offerId=${offer.offerId}');

    try {
      final req = await _http.postUrl(uri);
      req.headers.contentLength = 0;
      req.headers.set(TransportProtocol.headerDeviceId, responder.id);
      req.headers.set(
        TransportProtocol.headerDeviceName,
        Uri.encodeComponent(responder.name),
      );
      req.headers.set(TransportProtocol.headerPairOfferId, offer.offerId);
      req.headers.set(TransportProtocol.headerPairCode, offer.numericCode);
      req.headers.set(TransportProtocol.headerSignature, sig);
      final resp = await req.close();
      await resp.drain<void>();
      _log('response ${resp.statusCode}');
      return resp.statusCode == HttpStatus.ok
          ? PairingPostResult.ok
          : PairingPostResult.rejected;
    } catch (e, st) {
      developer.log('pair POST failed', error: e, stackTrace: st, name: _logName);
      _log('network error: $e');
      return PairingPostResult.networkError;
    }
  }

  void close() {
    _http.close(force: true);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
