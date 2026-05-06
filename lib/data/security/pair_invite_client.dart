import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../transport/transport_protocol.dart';
import 'pinning_http_client.dart';

/// Wire shape returned by the responder's /pair-invite handler when it
/// accepts the invite. Mirrors the body the responder writes; parsing
/// failures (missing field, bad base64, wrong key length) become null.
class PairInviteResponse {
  PairInviteResponse({
    required this.responderId,
    required this.responderName,
    required this.responderPublicKey,
    required this.responderEphemeralPublicKey,
    required this.responderCertFingerprintSha256,
    required this.signature,
  });

  final String responderId;
  final String responderName;
  final Uint8List responderPublicKey;
  final Uint8List responderEphemeralPublicKey;
  final String responderCertFingerprintSha256;
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

/// Outbound HTTP client for slice 4.6 pair-invite + pair-finalize.
///
/// **Slice 5.1 — TLS:** when [_overrideHttpClient] is null (production)
/// each request builds a fresh single-use [HttpClient] under TOFU
/// (since this is the first contact with the peer — we don't yet
/// have a pinned cert fingerprint). The captured fingerprint is
/// returned via [PairInviteResponse.responderCertFingerprintSha256]
/// so [PairInviteService.completeInvite] can verify it matches what
/// the peer claimed in their signed payload before persisting onto
/// the resulting [PairedDevice]. Tests can opt out of TLS by
/// constructing with an explicit plain [HttpClient].
class PairInviteClient {
  static const _logName = 'sharer.security.invite.client';

  PairInviteClient([HttpClient? http]) : _overrideHttpClient = http;

  final HttpClient? _overrideHttpClient;

  /// POST /pair-invite to a single host:port. Caller is expected to
  /// have picked the right candidate from the peer's announced
  /// addresses already — unlike QR pairing where the offer carries
  /// every local IP, the invite flow uses the peer we already
  /// discovered via mDNS, so `host:port` is unambiguous.
  ///
  /// [initiatorCertFingerprintSha256] is the local TLS server's cert
  /// fingerprint, embedded in the payload so the responder can pin
  /// it later.
  Future<PairInvitePostResult> postInvite({
    required String host,
    required int port,
    required String inviteId,
    required String initiatorId,
    required String initiatorName,
    required Uint8List initiatorPublicKey,
    required Uint8List initiatorEphemeralPublicKey,
    required String initiatorCertFingerprintSha256,
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
      'initiatorCertFingerprint': initiatorCertFingerprintSha256,
      'nonce': base64Encode(nonce),
      'signature': base64Encode(signature),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    final useTls = _overrideHttpClient == null;
    final scheme = useTls ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port'
        '${TransportProtocol.pairInvitePath}');
    _log('POST $uri inviteId=$inviteId');
    final http = _overrideHttpClient ??
        // TOFU: accept whatever cert the responder presents; the
        // payload's `responderCertFingerprint` is signed by their
        // Ed25519 so [PairInviteService.completeInvite] verifies the
        // match and rejects on tamper.
        buildPinningHttpClient(tofuSink: (_, _, _) {});
    final ownsClient = _overrideHttpClient == null;
    try {
      final req = await http.postUrl(uri).timeout(timeout);
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
        final certFp = j['responderCertFingerprint'] as String?;
        if (pub.length != 32 || eph.length != 32 || sig.length != 64) {
          return PairInvitePostMalformed('bad key/sig length');
        }
        if (certFp == null || certFp.isEmpty) {
          return PairInvitePostMalformed('missing responderCertFingerprint');
        }
        return PairInvitePostOk(PairInviteResponse(
          responderId: j['responderId'] as String,
          responderName: (j['responderName'] as String?) ?? '',
          responderPublicKey: pub,
          responderEphemeralPublicKey: eph,
          responderCertFingerprintSha256: certFp,
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
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  /// POST /pair-finalize. Body shape matches [PairInviteService]'s
  /// finalize canonical: `{inviteId, senderId, verdict, signature}`.
  /// Returns true on 200, false on anything else (including network).
  /// Failures are non-fatal — the in-flight TTL on the peer side will
  /// expire the entry naturally.
  ///
  /// [peerCertFingerprintSha256] is the cert fingerprint we already
  /// learned from the prior /pair-invite handshake (or, on the
  /// responder side, from the inbound invite payload). The pinning
  /// client rejects any cert whose hash doesn't match.
  Future<bool> postFinalize({
    required String host,
    required int port,
    required String inviteId,
    required String senderId,
    required String verdict,
    required String signatureBase64,
    required String peerCertFingerprintSha256,
    Duration timeout = _defaultTimeout,
  }) async {
    final body = jsonEncode({
      'inviteId': inviteId,
      'senderId': senderId,
      'verdict': verdict,
      'signature': signatureBase64,
    });
    final useTls = _overrideHttpClient == null;
    final scheme = useTls ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port'
        '${TransportProtocol.pairFinalizePath}');
    _log('POST $uri inviteId=$inviteId verdict=$verdict');
    final http = _overrideHttpClient ??
        buildPinningHttpClient(
            expectedFingerprint: peerCertFingerprintSha256);
    final ownsClient = _overrideHttpClient == null;
    try {
      final req = await http.postUrl(uri).timeout(timeout);
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
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  /// Slice 5.4: POST /peer-forgot-you. Best-effort: success and failure
  /// produce the same local outcome (the peer is removed regardless), so
  /// returning bool here is just for logging/instrumentation. The body
  /// shape is `{senderId, signature}` matching
  /// `peer_forget_signer.dart`'s canonical.
  ///
  /// Pinning: we already hold the peer's cert fingerprint on the
  /// PairedDevice we're about to forget — same pinning logic as
  /// /pair-finalize.
  Future<bool> postPeerForgotYou({
    required String host,
    required int port,
    required String senderId,
    required String signatureBase64,
    required String peerCertFingerprintSha256,
    Duration timeout = _defaultTimeout,
  }) async {
    final body = jsonEncode({
      'senderId': senderId,
      'signature': signatureBase64,
    });
    final useTls = _overrideHttpClient == null;
    final scheme = useTls ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port'
        '${TransportProtocol.peerForgotYouPath}');
    _log('POST $uri senderId=$senderId');
    final http = _overrideHttpClient ??
        buildPinningHttpClient(
            expectedFingerprint: peerCertFingerprintSha256);
    final ownsClient = _overrideHttpClient == null;
    try {
      final req = await http.postUrl(uri).timeout(timeout);
      final encoded = utf8.encode(body);
      req.headers.contentLength = encoded.length;
      req.headers.contentType = ContentType.json;
      req.add(encoded);
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      _log('peer-forgot-you response ${resp.statusCode} for $senderId');
      return resp.statusCode == HttpStatus.ok;
    } catch (e, st) {
      developer.log('peer-forgot-you POST failed',
          error: e, stackTrace: st, name: _logName);
      _log('peer-forgot-you network error to $host:$port: $e');
      return false;
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  void close() {
    _overrideHttpClient?.close(force: true);
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
