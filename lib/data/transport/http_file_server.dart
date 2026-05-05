import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../security/hmac_verifier.dart';
import '../security/pair_invite_service.dart';
import '../security/pairing_service.dart';
import '../security/tls_key_material.dart';
import '../storage/downloads_locator.dart';
import 'incoming_event.dart';
import 'transport_protocol.dart';

/// Receiving side of the file-transfer transport. shelf-based HTTPS
/// server (slice 5.1) — bound once on [start], stays bound through
/// trust transitions for the lifetime of the app so paired peers can
/// reach this device on any network. Streams uploads to disk — never
/// buffers a whole file in memory.
///
/// Trust state is no longer an authorization gate (it never was, per
/// docs/v1/security.md §5). What it gates now is which **routes** the
/// server exposes:
///
/// - `/upload` — always, signed-by-paired-peer is the only check.
/// - `/pair`, `/pair-invite`, `/pair-finalize` — only when trusted.
///   Untrusted networks return 404 from these handlers as if the
///   route weren't registered. See architecture.md "Transport —
///   strong rules" #1 + #2.
class HttpFileServer {
  static const _logName = 'sharer.transport.server';

  /// Emit a progress event at most once per ~256 KB to keep UI rebuilds
  /// reasonable on large transfers.
  static const _progressThresholdBytes = 256 * 1024;

  final DownloadsLocator _downloads;
  final Stream<bool> _isTrusted;
  final HmacVerifier? _verifier;
  final PairingService? _pairing;
  final PairInviteService? _invite;

  /// Slice 5.1 TLS material. When non-null the server binds with HTTPS;
  /// when null (test convenience) it falls back to plain HTTP. Production
  /// providers always wire a real [TlsKeyMaterial]. Held as a Future so
  /// the composition root can resolve it lazily without making the
  /// provider itself async.
  final Future<TlsKeyMaterial>? _tlsFuture;

  final int _port;
  final Uuid _uuid;

  final _events = StreamController<IncomingEvent>.broadcast();
  HttpServer? _httpServer;
  StreamSubscription<bool>? _trustSub;

  bool _started = false;

  /// Latest trust value from the watcher. Pair routes consult this on
  /// every request; `/upload` ignores it (per slice 4.4 the HMAC gate
  /// is the only authorization).
  bool _isTrustedNow = false;

  HttpFileServer({
    required DownloadsLocator downloads,
    required Stream<bool> isTrusted,
    HmacVerifier? verifier,
    PairingService? pairing,
    PairInviteService? invite,
    Future<TlsKeyMaterial>? tlsMaterial,
    int port = TransportProtocol.defaultPort,
    Uuid? uuid,
  })  : _downloads = downloads,
        _isTrusted = isTrusted,
        _verifier = verifier,
        _pairing = pairing,
        _invite = invite,
        _tlsFuture = tlsMaterial,
        _port = port,
        _uuid = uuid ?? const Uuid();

  Stream<IncomingEvent> get events => _events.stream;

  /// Actual bound port (useful in tests when [_port] is 0).
  int? get boundPort => _httpServer?.port;

  bool get isRunning => _httpServer != null;

  /// Bind + start listening. The server stays bound until [stop] —
  /// trust transitions only flip what pair routes do, not the socket.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _trustSub = _isTrusted.listen((trusted) {
      _log('Trust → $trusted (route gate only; socket stays bound)');
      _isTrustedNow = trusted;
    });
    await _bind();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _log('Stopping');
    await _trustSub?.cancel();
    _trustSub = null;
    await _unbind();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _bind() async {
    if (_httpServer != null) return;
    // Resolve the TLS material first so we can log the actual scheme.
    // This await is intentionally inside _bind: providers stay sync;
    // the cost (ECDSA keygen ~50ms on first call, free thereafter) is
    // paid once at startup.
    final tls = await _tlsFuture;
    final scheme = tls == null ? 'HTTP' : 'HTTPS';
    _log('Binding $scheme server on port $_port');
    final router = Router();
    router.post(TransportProtocol.uploadPath, _handleUpload);
    // All pair routes are always registered — the handlers themselves
    // self-gate on [_isTrustedNow]. Registering them once at bind time
    // means trust transitions don't have to rebuild the router.
    if (_pairing != null) {
      router.post(TransportProtocol.pairPath, _handlePair);
    }
    if (_invite != null) {
      router.post(TransportProtocol.pairInvitePath, _handlePairInvite);
      router.post(TransportProtocol.pairFinalizePath, _handlePairFinalize);
    }
    final handler = const Pipeline().addHandler(router.call);
    try {
      if (tls == null) {
        _httpServer = await shelf_io.serve(
          handler,
          InternetAddress.anyIPv4,
          _port,
        );
      } else {
        final ctx = SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(tls.certificatePem.codeUnits)
          ..usePrivateKeyBytes(tls.privateKeyPem.codeUnits);
        _httpServer = await shelf_io.serve(
          handler,
          InternetAddress.anyIPv4,
          _port,
          securityContext: ctx,
        );
      }
      _log('$scheme server listening on '
          '${_httpServer!.address.address}:${_httpServer!.port}'
          '${tls == null ? '' : ' (fingerprint=${tls.certificateFingerprintSha256})'}');
    } catch (e, st) {
      _log('Bind failed: $e');
      developer.log('Bind failed', error: e, stackTrace: st, name: _logName);
      _httpServer = null;
      rethrow;
    }
  }

  Future<void> _unbind() async {
    final s = _httpServer;
    if (s == null) return;
    _httpServer = null;
    _log('Unbinding server');
    await s.close(force: true);
  }

  // ---- Request handling ----

  Future<Response> _handleUpload(Request request) async {
    final headers = request.headers;
    final fileName = _decodeHeader(headers[TransportProtocol.headerFileName]);
    final totalBytes =
        int.tryParse(headers[TransportProtocol.headerFileSize] ?? '') ?? 0;
    final senderId = headers[TransportProtocol.headerDeviceId] ?? 'unknown';
    final senderName = _decodeHeader(headers[TransportProtocol.headerDeviceName]) ??
        'Unknown device';

    if (fileName == null || fileName.isEmpty) {
      return Response.badRequest(
        body: 'missing or empty ${TransportProtocol.headerFileName}',
      );
    }

    // HMAC gate (slice 4.4 policy).
    //
    // Pairing is the only path to /upload. Unsigned and unverified
    // requests both return 401, regardless of network trust state — the
    // network watcher is a discoverability control, not an authorization
    // mechanism. See docs/v1/security.md §5 and the strong rules in
    // docs/v1/architecture.md.
    //
    // Test convenience only: when the server is constructed with
    // `verifier: null`, the gate is disabled. Production providers
    // always wire a real verifier.
    final verifier = _verifier;
    if (verifier != null) {
      final outcome = await verifier.verify(
        method: 'POST',
        path: TransportProtocol.uploadPath,
        senderDeviceId: senderId,
        timestamp: headers[TransportProtocol.headerTimestamp],
        nonce: headers[TransportProtocol.headerNonce],
        signature: headers[TransportProtocol.headerSignature],
        filename: fileName,
        filesize: totalBytes,
      );
      switch (outcome) {
        case HmacAuthenticated():
          break;
        case HmacUnsigned():
          _log('Reject upload from $senderId ($senderName): unsigned');
          await request.read().drain<void>();
          return Response.unauthorized('');
        case HmacRejected(:final reason):
          _log('Reject upload from $senderId ($senderName): $reason');
          await request.read().drain<void>();
          return Response.unauthorized('');
      }
    }

    final id = _uuid.v4();
    final dir = await _downloads.directory();
    final safeName = _sanitizeFileName(fileName);
    final destFile = await _resolveUniqueDestination(dir, safeName);

    _log('Receive start id=$id from $senderName ($senderId) → ${destFile.path}');
    _events.add(IncomingStarted(
      id: id,
      fileName: destFile.uri.pathSegments.last,
      totalBytes: totalBytes,
      senderId: senderId,
      senderName: senderName,
    ));

    final sink = destFile.openWrite();
    var bytesReceived = 0;
    var lastEmittedBytes = 0;
    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (bytesReceived - lastEmittedBytes >= _progressThresholdBytes) {
          _events.add(IncomingProgress(id: id, bytesReceived: bytesReceived));
          lastEmittedBytes = bytesReceived;
        }
      }
      await sink.flush();
      await sink.close();
      _events.add(IncomingProgress(id: id, bytesReceived: bytesReceived));
      _events.add(IncomingCompleted(id: id, savedPath: destFile.path));
      _log('Receive done id=$id bytes=$bytesReceived path=${destFile.path}');
      return Response.ok(
        jsonEncode({
          'savedPath': destFile.path,
          'bytesReceived': bytesReceived,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, st) {
      _log('Receive failed id=$id: $e');
      developer.log('Receive failed', error: e, stackTrace: st, name: _logName);
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await destFile.exists()) await destFile.delete();
      } catch (_) {}
      _events.add(IncomingFailed(id: id, error: e.toString()));
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _handlePairInvite(Request request) async {
    if (!_isTrustedNow) {
      _log('pair-invite refused: untrusted network (route gate)');
      return Response.notFound('');
    }
    final invite = _invite!;
    final raw = await request.readAsString();
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _log('pair-invite reject: malformed JSON');
      return Response.badRequest();
    }
    Uint8List dec(String key) =>
        Uint8List.fromList(base64Decode(j[key] as String));
    String? inviteId;
    String? initiatorId;
    String? initiatorName;
    Uint8List initiatorPublicKey;
    Uint8List initiatorEphemeralPublicKey;
    String initiatorCertFingerprint;
    Uint8List nonce;
    Uint8List signature;
    DateTime expiresAt;
    try {
      inviteId = j['inviteId'] as String;
      initiatorId = j['initiatorId'] as String;
      initiatorName = (j['initiatorName'] as String?) ?? 'Unknown device';
      initiatorPublicKey = dec('initiatorPublicKey');
      initiatorEphemeralPublicKey = dec('initiatorEphemeralPublicKey');
      initiatorCertFingerprint = j['initiatorCertFingerprint'] as String;
      nonce = dec('nonce');
      signature = dec('signature');
      expiresAt = DateTime.parse(j['expiresAt'] as String);
    } catch (e) {
      _log('pair-invite reject: missing/malformed field: $e');
      return Response.badRequest();
    }
    // Slice 5.1: the responder's own TLS cert fingerprint travels with
    // the invite acceptance so the initiator can pin us. Pulled from
    // the cached TLS material (same one the server bound with).
    final tls = await _tlsFuture;
    if (tls == null) {
      _log('pair-invite reject: server has no TLS material');
      return Response.internalServerError();
    }
    final result = await invite.acceptInvite(
      inviteId: inviteId,
      initiatorId: initiatorId,
      initiatorName: initiatorName,
      initiatorPublicKey: initiatorPublicKey,
      initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
      initiatorCertFingerprintSha256: initiatorCertFingerprint,
      nonce: nonce,
      signature: signature,
      expiresAt: expiresAt,
      localCertFingerprintSha256: tls.certificateFingerprintSha256,
    );
    switch (result) {
      case PairInviteAccepted(
          :final responderId,
          :final responderName,
          :final responderPublicKey,
          :final responderEphemeralPublicKey,
          :final responderCertFingerprintSha256,
          :final signature,
        ):
        return Response.ok(
          jsonEncode({
            'responderId': responderId,
            'responderName': responderName,
            'responderPublicKey': base64Encode(responderPublicKey),
            'responderEphemeralPublicKey':
                base64Encode(responderEphemeralPublicKey),
            'responderCertFingerprint': responderCertFingerprintSha256,
            'signature': base64Encode(signature),
          }),
          headers: {'content-type': 'application/json'},
        );
      case PairInviteRateLimited(:final reason):
        _log('pair-invite rate-limited: $reason');
        return Response(429);
      case PairInviteRejected(:final reason):
        _log('pair-invite rejected: $reason');
        return Response.unauthorized('');
    }
  }

  Future<Response> _handlePairFinalize(Request request) async {
    if (!_isTrustedNow) {
      _log('pair-finalize refused: untrusted network (route gate)');
      return Response.notFound('');
    }
    final invite = _invite!;
    final raw = await request.readAsString();
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return Response.badRequest();
    }
    String inviteId;
    String senderId;
    String verdict;
    String signatureBase64;
    try {
      inviteId = j['inviteId'] as String;
      senderId = j['senderId'] as String;
      verdict = j['verdict'] as String;
      signatureBase64 = j['signature'] as String;
    } catch (_) {
      return Response.badRequest();
    }
    final result = await invite.recordRemoteFinalize(
      inviteId: inviteId,
      senderId: senderId,
      verdict: verdict,
      signatureBase64: signatureBase64,
    );
    switch (result) {
      case PairFinalizeRecorded():
        return Response.ok('');
      case PairFinalizeUnknown():
        return Response.notFound('');
      case PairFinalizeRejected():
        return Response.unauthorized('');
    }
  }

  Future<Response> _handlePair(Request request) async {
    if (!_isTrustedNow) {
      _log('pair refused: untrusted network (route gate)');
      return Response.notFound('');
    }
    final pairing = _pairing!;
    final headers = request.headers;
    final responderId = headers[TransportProtocol.headerDeviceId];
    final responderName =
        _decodeHeader(headers[TransportProtocol.headerDeviceName]) ??
            'Unknown device';
    final offerId = headers[TransportProtocol.headerPairOfferId];
    final code = headers[TransportProtocol.headerPairCode];
    final signature = headers[TransportProtocol.headerSignature];
    final publicKeyB64 = headers[TransportProtocol.headerPublicKey];
    final identitySig = headers[TransportProtocol.headerIdentitySignature];

    if (responderId == null ||
        responderId.isEmpty ||
        offerId == null ||
        offerId.isEmpty ||
        code == null ||
        code.isEmpty ||
        signature == null ||
        signature.isEmpty ||
        publicKeyB64 == null ||
        publicKeyB64.isEmpty ||
        identitySig == null ||
        identitySig.isEmpty) {
      _log('Reject pair: missing required headers');
      await request.read().drain<void>();
      return Response.unauthorized('');
    }

    Uint8List publicKey;
    try {
      publicKey = Uint8List.fromList(base64Decode(publicKeyB64));
    } catch (_) {
      _log('Reject pair: malformed publicKey base64');
      await request.read().drain<void>();
      return Response.unauthorized('');
    }

    // Slice 5.1: optional — present iff the responder is post-5.1.
    // Persisted on the resulting [PairedDevice] so future hot-path
    // /upload requests pin against the responder's TLS cert.
    final responderCertFp = headers[TransportProtocol.headerCertFingerprint];

    final paired = await pairing.completePair(
      offerId: offerId,
      numericCode: code,
      responderId: responderId,
      responderName: responderName,
      responderPublicKey: publicKey,
      signature: signature,
      identitySignature: identitySig,
      responderCertFingerprint: responderCertFp,
    );
    await request.read().drain<void>();
    if (paired == null) return Response.unauthorized('');
    return Response.ok(
      jsonEncode({'pairedAs': paired.deviceId}),
      headers: {'content-type': 'application/json'},
    );
  }

  static String? _decodeHeader(String? value) {
    if (value == null) return null;
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// Strip path separators and parent-directory traversal so a
  /// malicious sender can't write outside the downloads dir.
  static String _sanitizeFileName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/]'), '_');
    s = s.replaceAll('..', '_');
    s = s.trim();
    if (s.isEmpty) s = 'file';
    return s;
  }

  /// If `foo.txt` exists in [dir], returns `foo (1).txt`, then
  /// `foo (2).txt`, etc. Avoids clobbering existing downloads.
  Future<File> _resolveUniqueDestination(Directory dir, String name) async {
    var candidate = File('${dir.path}${Platform.pathSeparator}$name');
    if (!await candidate.exists()) return candidate;

    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    for (var i = 1; i < 10000; i++) {
      candidate = File('${dir.path}${Platform.pathSeparator}$stem ($i)$ext');
      if (!await candidate.exists()) return candidate;
    }
    // Extremely unlikely fallback — append a random tag.
    return File('${dir.path}${Platform.pathSeparator}$stem-${_uuid.v4()}$ext');
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
