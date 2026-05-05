import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../transport/transport_protocol.dart';

/// Wire shape returned by the responder's /pair-invite handler when it
/// accepts the invite. Mirrors the body the responder writes; parsing
/// failures (missing field, bad base64, wrong key length) become null.
class PairInviteResponse {
  PairInviteResponse({
    required this.responderId,
    required this.responderName,
    required this.responderPublicKey,
    required this.responderEphemeralPublicKey,
    required this.signature,
  });

  final String responderId;
  final String responderName;
  final Uint8List responderPublicKey;
  final Uint8List responderEphemeralPublicKey;
  final Uint8List signature;
}

/// Outcome of POSTing /pair-invite. Caller maps these to either a
/// fingerprint modal or a user-visible error.
sealed class PairInvitePostResult {}

class PairInvitePostOk extends PairInvitePostResult {
  PairInvitePostOk(this.response);
  final PairInviteResponse response;
}

class PairInvitePostDeclined extends PairInvitePostResult {
  PairInvitePostDeclined(this.statusCode, this.reason);
  final int statusCode;
  final String reason;
}

class PairInvitePostNetworkError extends PairInvitePostResult {
  PairInvitePostNetworkError(this.cause);
  final Object cause;
}

class PairInvitePostMalformed extends PairInvitePostResult {
  PairInvitePostMalformed(this.reason);
  final String reason;
}

const Duration _defaultTimeout = Duration(seconds: 8);

/// Outbound HTTP client for slice 4.6 pair-invite + pair-finalize. Kept
/// separate from [PairingClient] (slice 4.3 QR flow) and [HttpFileClient]
/// (transfers) so each can evolve independently — TLS in slice 5.1 will
/// land first on the file client, the pair clients pick it up later.
class PairInviteClient {
  static const _logName = 'sharer.security.invite.client';

  PairInviteClient([HttpClient? http]) : _http = http ?? HttpClient();

  final HttpClient _http;

  /// POST /pair-invite to a single host:port. Caller is expected to
  /// have picked the right candidate from the peer's announced
  /// addresses already — unlike QR pairing where the offer carries
  /// every local IP, the invite flow uses the peer we already
  /// discovered via mDNS, so `host:port` is unambiguous.
  Future<PairInvitePostResult> postInvite({
    required String host,
    required int port,
    required String inviteId,
    required String initiatorId,
    required String initiatorName,
    required Uint8List initiatorPublicKey,
    required Uint8List initiatorEphemeralPublicKey,
    required Uint8List nonce,
    required Uint8List signature,
    required DateTime expiresAt,
    Duration timeout = _defaultTimeout,
  }) async {
    final body = jsonEncode({
      'inviteId': inviteId,
      'initiatorId': initiatorId,
      'initiatorName': initiatorName,
      'initiatorPublicKey': base64Encode(initiatorPublicKey),
      'initiatorEphemeralPublicKey': base64Encode(initiatorEphemeralPublicKey),
      'nonce': base64Encode(nonce),
      'signature': base64Encode(signature),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    final uri = Uri.parse(
        'http://$host:$port${TransportProtocol.pairInvitePath}');
    _log('POST $uri inviteId=$inviteId');
    try {
      final req = await _http.postUrl(uri).timeout(timeout);
      final encoded = utf8.encode(body);
      req.headers.contentLength = encoded.length;
      req.headers.contentType = ContentType.json;
      req.add(encoded);
      final resp = await req.close().timeout(timeout);
      final respBody = await resp.transform(utf8.decoder).join();
      _log('response ${resp.statusCode} from $host:$port');
      if (resp.statusCode != HttpStatus.ok) {
        return PairInvitePostDeclined(resp.statusCode, respBody);
      }
      try {
        final j = jsonDecode(respBody) as Map<String, dynamic>;
        final pub = Uint8List.fromList(
            base64Decode(j['responderPublicKey'] as String));
        final eph = Uint8List.fromList(
            base64Decode(j['responderEphemeralPublicKey'] as String));
        final sig = Uint8List.fromList(base64Decode(j['signature'] as String));
        if (pub.length != 32 || eph.length != 32 || sig.length != 64) {
          return PairInvitePostMalformed('bad key/sig length');
        }
        return PairInvitePostOk(PairInviteResponse(
          responderId: j['responderId'] as String,
          responderName: (j['responderName'] as String?) ?? '',
          responderPublicKey: pub,
          responderEphemeralPublicKey: eph,
          signature: sig,
        ));
      } catch (e) {
        return PairInvitePostMalformed('parse: $e');
      }
    } catch (e, st) {
      developer.log('pair-invite POST failed',
          error: e, stackTrace: st, name: _logName);
      _log('network error to $host:$port: $e');
      return PairInvitePostNetworkError(e);
    }
  }

  /// POST /pair-finalize. Body shape matches [PairInviteService]'s
  /// [finalize] canonical: `{inviteId, senderId, verdict, signature}`.
  /// Returns true on 200, false on anything else (including network).
  /// Failures are non-fatal — the in-flight TTL on the peer side will
  /// expire the entry naturally.
  Future<bool> postFinalize({
    required String host,
    required int port,
    required String inviteId,
    required String senderId,
    required String verdict,
    required String signatureBase64,
    Duration timeout = _defaultTimeout,
  }) async {
    final body = jsonEncode({
      'inviteId': inviteId,
      'senderId': senderId,
      'verdict': verdict,
      'signature': signatureBase64,
    });
    final uri = Uri.parse(
        'http://$host:$port${TransportProtocol.pairFinalizePath}');
    _log('POST $uri inviteId=$inviteId verdict=$verdict');
    try {
      final req = await _http.postUrl(uri).timeout(timeout);
      final encoded = utf8.encode(body);
      req.headers.contentLength = encoded.length;
      req.headers.contentType = ContentType.json;
      req.add(encoded);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      _log('finalize response ${resp.statusCode} for $inviteId');
      return resp.statusCode == HttpStatus.ok;
    } catch (e, st) {
      developer.log('pair-finalize POST failed',
          error: e, stackTrace: st, name: _logName);
      _log('finalize network error to $host:$port: $e');
      return false;
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
