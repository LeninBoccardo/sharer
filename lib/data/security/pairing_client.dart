import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/pairing_offer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../transport/transport_protocol.dart';
import 'pairing_service.dart';

/// Outcome of the responder-side /pair POST.
enum PairingPostResult {
  ok,
  rejected,
  networkError,
  malformedEndpoint,
}

/// Default per-attempt connect timeout when iterating offer endpoints.
/// Pairing should feel instant on the same LAN, but waiting the full OS
/// SYN-retransmit window for an unreachable IP would delay falling
/// through to the next candidate.
const _defaultPerEndpointTimeout = Duration(seconds: 4);

/// Responder-side HTTP client for the /pair handshake. Separate from
/// [HttpFileClient] so the pairing path doesn't drag the upload code
/// down with it (and so we can swap the transport for TLS in slice 5
/// without touching transfers).
class PairingClient {
  static const _logName = 'sharer.security.pairing.client';

  final HttpClient _http;

  PairingClient([HttpClient? http]) : _http = http ?? HttpClient();

  /// POSTs the completion handshake to one of the offer's endpoints. The
  /// initiator embeds every local IPv4 because we can't tell up-front
  /// which one the responder will be able to route to. We try them in
  /// order and keep the first that doesn't fail at the socket layer:
  ///
  ///   - 200 → ok, return immediately
  ///   - any other status → rejected, return immediately (the request
  ///     reached an initiator that refused us; trying another IP won't help)
  ///   - socket error → try the next endpoint
  ///
  /// If every endpoint is malformed, return malformedEndpoint. If every
  /// endpoint fails at the socket layer, return networkError. Mixed
  /// malformed+networkError counts as networkError so the user sees the
  /// more specific "we couldn't reach the device" message.
  Future<PairingPostResult> postCompletion({
    required PairingOffer offer,
    required DeviceIdentity responder,
    required DeviceIdentityRepository identityRepo,
    Duration perEndpointTimeout = _defaultPerEndpointTimeout,
  }) async {
    if (offer.endpoints.isEmpty) {
      return PairingPostResult.malformedEndpoint;
    }
    final canonical = pairingCanonicalString(
      offerId: offer.offerId,
      responderId: responder.id,
      numericCode: offer.numericCode,
    );
    final canonicalBytes = utf8.encode(canonical);
    final mac = Hmac(sha256, offer.psk).convert(canonicalBytes);
    final sig = base64Encode(mac.bytes);
    final identitySig = base64Encode(await identityRepo.sign(canonicalBytes));
    final pubKey = base64Encode(responder.publicKey);

    var sawNetworkError = false;
    var sawMalformed = false;
    for (final endpoint in offer.endpoints) {
      final parsed = _parseEndpoint(endpoint);
      if (parsed == null) {
        sawMalformed = true;
        _log('skip malformed endpoint: $endpoint');
        continue;
      }
      final uri = Uri.parse(
          'http://${parsed.host}:${parsed.port}${TransportProtocol.pairPath}');
      _log('POST $uri offerId=${offer.offerId}');
      try {
        final req = await _http.postUrl(uri).timeout(perEndpointTimeout);
        req.headers.contentLength = 0;
        req.headers.set(TransportProtocol.headerDeviceId, responder.id);
        req.headers.set(
          TransportProtocol.headerDeviceName,
          Uri.encodeComponent(responder.name),
        );
        req.headers.set(TransportProtocol.headerPairOfferId, offer.offerId);
        req.headers.set(TransportProtocol.headerPairCode, offer.numericCode);
        req.headers.set(TransportProtocol.headerSignature, sig);
        req.headers.set(TransportProtocol.headerPublicKey, pubKey);
        req.headers
            .set(TransportProtocol.headerIdentitySignature, identitySig);
        final resp = await req.close().timeout(perEndpointTimeout);
        await resp.drain<void>();
        _log('response ${resp.statusCode} from $endpoint');
        return resp.statusCode == HttpStatus.ok
            ? PairingPostResult.ok
            : PairingPostResult.rejected;
      } catch (e, st) {
        developer.log('pair POST to $endpoint failed',
            error: e, stackTrace: st, name: _logName);
        _log('network error on $endpoint: $e');
        sawNetworkError = true;
      }
    }
    if (sawNetworkError) return PairingPostResult.networkError;
    if (sawMalformed) return PairingPostResult.malformedEndpoint;
    return PairingPostResult.networkError;
  }

  static ({String host, int port})? _parseEndpoint(String endpoint) {
    final colon = endpoint.lastIndexOf(':');
    if (colon < 0 || colon == endpoint.length - 1) return null;
    final port = int.tryParse(endpoint.substring(colon + 1));
    if (port == null) return null;
    final host = endpoint.substring(0, colon);
    if (host.isEmpty) return null;
    return (host: host, port: port);
  }

  void close() {
    _http.close(force: true);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
