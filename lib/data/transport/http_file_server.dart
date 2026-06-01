import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/paired_device.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../security/forget_service.dart';
import '../security/hmac_verifier.dart';
import '../security/pair_invite_service.dart';
import '../security/pairing_service.dart';
import '../security/peer_forget_signer.dart';
import '../security/tls_key_material.dart';
import '../security/transfer_cipher.dart';
import '../storage/downloads_locator.dart';
import 'incoming_event.dart';
import 'transport_protocol.dart';

/// Slice 5.x.2.5: regex matching every Unicode bidi-formatting control
/// (UAX #9: LRM, RLM, LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI, ALM)
/// — the codepoints that let a malicious filename render with a
/// flipped extension in Explorer / Finder while keeping the real
/// `.exe` on disk.
///
/// Built from numeric codepoints (not literal characters) so this
/// source file itself stays pure ASCII; the linter rightly flags any
/// literal bidi control in source as a code-review hazard.
final RegExp _bidiControlsPattern = RegExp(String.fromCharCodes(<int>[
  0x5B, // [
  0x200E, 0x200F, // LRM, RLM
  0x202A, 0x2D, 0x202E, // LRE through RLO (range)
  0x2066, 0x2D, 0x2069, // LRI through PDI (range)
  0x061C, // ALM
  0x5D, // ]
]));

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

  /// Audit #8: hard cap on the in-RAM body size for the three small JSON
  /// endpoints (/peer-forgot-you, /pair-invite, /pair-finalize). Their
  /// real payloads are well under ~2 KB; 64 KB is a generous ceiling
  /// that still makes a pre-auth OOM flood impossible. Does NOT apply to
  /// /upload — that streams arbitrarily large bodies straight to disk
  /// via request.read() and is never read into memory.
  static const _maxJsonBodyBytes = 64 * 1024;

  /// Audit #25: generous absolute per-transfer write ceiling. The product
  /// principle is any-file/any-size with NO hard cap on legit transfers,
  /// and dart:io has no portable free-disk-space query ([FileStat] carries
  /// no free-space field). So instead of a true free-space check we
  /// enforce a ceiling set far above any realistic transfer purely to stop
  /// a paired-but-malicious peer from streaming an unbounded body straight
  /// to disk and filling the volume. A legitimate sender never approaches
  /// it; an abusive one is cut off with a 507.
  ///
  /// LIMITATION: an absolute ceiling, not free-space awareness — it does
  /// NOT protect a device whose disk is already nearly full when a
  /// sub-ceiling transfer arrives. A future platform channel (Android
  /// StatFs, Win32 GetDiskFreeSpaceEx, POSIX statvfs) can compute a
  /// per-call floor; [maxTransferBytes] is injectable so that override is
  /// a drop-in with no change to the receive loop.
  static const int defaultMaxTransferBytes = 512 * 1024 * 1024 * 1024;

  final DownloadsLocator _downloads;

  /// Audit #25: effective per-transfer write ceiling for this server.
  /// Defaults to [defaultMaxTransferBytes]; injectable for tests and a
  /// future free-space-aware composition root.
  final int _maxTransferBytes;
  final Stream<bool> _isTrusted;
  final HmacVerifier? _verifier;
  final PairingService? _pairing;
  final PairInviteService? _invite;

  /// Slice 5.4: optional. When wired, every HMAC-verified inbound
  /// request caches the sender's source IP so subsequent outbound
  /// transfers prefer it over bonsoir's resolved peer.host. Also
  /// activates the `/peer-forgot-you` route (shares the same
  /// PairedDevices repo for HMAC validation).
  final PeerCacheRepository? _peerCache;
  final ForgetService? _forget;

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
    PeerCacheRepository? peerCache,
    ForgetService? forget,
    Future<TlsKeyMaterial>? tlsMaterial,
    int port = TransportProtocol.defaultPort,
    int maxTransferBytes = defaultMaxTransferBytes,
    Uuid? uuid,
  })  : _downloads = downloads,
        _isTrusted = isTrusted,
        _verifier = verifier,
        _pairing = pairing,
        _invite = invite,
        _peerCache = peerCache,
        _forget = forget,
        _tlsFuture = tlsMaterial,
        _port = port,
        _maxTransferBytes = maxTransferBytes,
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
    // Slice 5.4: peer-forgot-you. Always registered when a forget
    // service is wired — like /upload it doesn't gate on network trust
    // because a paired peer must be able to reach us anywhere to tell
    // us they're done. The handler itself enforces HMAC against the
    // PairedDevice store.
    if (_forget != null && _verifier != null) {
      router.post(TransportProtocol.peerForgotYouPath, _handlePeerForgotYou);
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
    final transferIdB64 = headers[TransportProtocol.headerTransferId];

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
    PairedDevice? authenticatedDevice;
    if (verifier != null) {
      final outcome = await verifier.verify(
        request: request,
        senderDeviceId: senderId,
        timestamp: headers[TransportProtocol.headerTimestamp],
        nonce: headers[TransportProtocol.headerNonce],
        signature: headers[TransportProtocol.headerSignature],
        filename: fileName,
        filesize: totalBytes,
        transferId: transferIdB64,
      );
      switch (outcome) {
        case HmacAuthenticated(:final device):
          authenticatedDevice = device;
        case HmacUnsigned():
          _log('Reject upload from $senderId ($senderName): unsigned');
          await request.read().drain<void>();
          return Response.unauthorized('');
        case HmacRejected(:final detail, :final reason):
          _log('Reject upload from $senderId ($senderName): $detail');
          await request.read().drain<void>();
          // Audit #1: only an unknown-sender rejection means the peer
          // doesn't recognize our identity/PSK — surface it distinctly so
          // the sender can reactively forget us. Every transient signing
          // failure stays a bare 401 (no reason header) so it never
          // unpairs a still-valid peer.
          if (reason == HmacRejectionReason.unknownSender) {
            return Response.forbidden('', headers: {
              TransportProtocol.headerReason:
                  TransportProtocol.reasonUnknownSender,
            });
          }
          return Response.unauthorized('');
      }
    }

    // Slice 5.4: an HMAC-verified inbound proves the sender's source IP
    // can reach us. Cache it so future outbound transfers prefer this
    // address over bonsoir-resolved peer.host (which on Realme has been
    // observed overwriting itself with the local device's own IP).
    if (authenticatedDevice != null) {
      await _cacheSourceAddress(
        request: request,
        device: authenticatedDevice,
      );
    }

    // Slice 5.3: when the request was authenticated AND a transferId
    // is present, the body is encrypted. Derive the per-transfer key
    // and pipe the inbound stream through the chunk decryptor.
    //
    // Production: the client always sends the transferId on a signed
    // upload, so this path is taken every time. Tests that exercise
    // the unsigned/null-verifier convenience path keep the plaintext
    // shape.
    TransferCipher? cipher;
    if (authenticatedDevice != null && transferIdB64 != null) {
      try {
        final transferIdBytes =
            Uint8List.fromList(base64Decode(transferIdB64));
        cipher = await TransferCipher.derive(
          psk: authenticatedDevice.psk,
          transferId: transferIdBytes,
        );
      } catch (e) {
        _log('Reject upload from $senderId ($senderName): '
            'malformed transferId: $e');
        await request.read().drain<void>();
        return Response.unauthorized('');
      }
    } else if (authenticatedDevice != null && transferIdB64 == null) {
      // Authenticated but no transferId — a signed-but-unencrypted
      // request. Slice 5.3 makes encryption mandatory between paired
      // peers, so reject. Same 401 to avoid leaking which check failed.
      _log('Reject upload from $senderId ($senderName): missing transferId');
      await request.read().drain<void>();
      return Response.unauthorized('');
    }

    final id = _uuid.v4();
    final dir = await _downloads.directory();
    final safeName = _sanitizeFileName(fileName);
    final destFile = await _resolveUniqueDestination(dir, safeName);

    _log('Receive start id=$id from $senderName ($senderId) → ${destFile.path}'
        ' encrypted=${cipher != null}');
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
      final body = cipher == null
          ? request.read()
          : cipher.decrypt(request.read());
      await for (final chunk in body) {
        bytesReceived += chunk.length;
        // Audit #25: abort before writing a chunk that would push the
        // file past the per-transfer capacity ceiling. Checked on the
        // post-increment running total (decrypted/plaintext bytes that
        // actually hit disk), so a sender that lies about or omits the
        // declared filesize header still can't fill the volume. Close +
        // delete the partial, drain the rest of the body so the socket
        // closes cleanly, and answer 507 with a coarse reason so the
        // sender shows "out of space", not a generic failure — and so it
        // does NOT trip the reactive-forget path (403 + unknown-sender).
        if (bytesReceived > _maxTransferBytes) {
          _log('Receive abort id=$id from $senderName ($senderId): '
              'exceeded capacity ceiling $_maxTransferBytes bytes');
          await sink.close();
          try {
            if (await destFile.exists()) await destFile.delete();
          } catch (_) {}
          _events.add(IncomingFailed(
            id: id,
            error: 'transfer exceeded capacity ceiling '
                '($_maxTransferBytes bytes)',
          ));
          // Guarded drain: draining a decrypt stream after an abort can
          // throw on malformed remainder; a bare throw here would escape
          // and mask the 507 with a 500.
          try {
            await body.drain<void>();
          } catch (_) {}
          return Response(
            507,
            headers: {
              TransportProtocol.headerReason:
                  TransportProtocol.reasonStorageFull,
            },
          );
        }
        sink.add(chunk);
        if (bytesReceived - lastEmittedBytes >= _progressThresholdBytes) {
          _events.add(IncomingProgress(id: id, bytesReceived: bytesReceived));
          lastEmittedBytes = bytesReceived;
        }
      }
      await sink.flush();
      await sink.close();
      // Slice 5.3.1: on Android, [destFile] is in a private staging
      // directory; publish it into the user-visible Downloads folder
      // and report THAT path. On other platforms publish is a no-op
      // returning destFile.path.
      final publishedPath = await _downloads.publish(
        tempFile: destFile,
        displayName: destFile.uri.pathSegments.last,
        mimeType: request.headers['content-type'],
      );
      _events.add(IncomingProgress(id: id, bytesReceived: bytesReceived));
      _events.add(IncomingCompleted(id: id, savedPath: publishedPath));
      _log('Receive done id=$id bytes=$bytesReceived path=$publishedPath');
      return Response.ok(
        jsonEncode({
          'savedPath': publishedPath,
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
    final raw = await _readBodyCapped(request, _maxJsonBodyBytes);
    if (raw == null) {
      _log('pair-invite reject: body exceeds $_maxJsonBodyBytes bytes');
      return Response(413);
    }
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
    // Slice 5.1.2: capture the source IP of the inbound POST so the
    // reciprocal /pair-finalize goes back through the same route.
    // Bonsoir on Windows can resolve the initiator's mDNS hostname to
    // an unreachable IPv6 / wrong-interface IP (real-device freeze
    // surfaced during slice 5.2.1 validation).
    final initiatorRemoteHost = _readRemoteHost(request);
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
      initiatorRemoteHost: initiatorRemoteHost,
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
    final raw = await _readBodyCapped(request, _maxJsonBodyBytes);
    if (raw == null) {
      _log('pair-finalize reject: body exceeds $_maxJsonBodyBytes bytes');
      return Response(413);
    }
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
        // Slice 5.4: HMAC-verified pair-finalize is just as solid a
        // proof of "this peer reaches us at this IP" as /upload. Cache
        // the source address under their deviceId.
        if (_peerCache != null) {
          final host = _readRemoteHost(request);
          if (host != null) {
            await _peerCache.cacheAddress(
              deviceId: senderId,
              host: host,
              port: TransportProtocol.defaultPort,
            );
          }
        }
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

  /// Slice 5.4: handles `/peer-forgot-you`. The body shape is
  /// `{senderId, signature}` where signature is HMAC-SHA256 over the
  /// canonical from `peer_forget_signer.dart` using the per-pair PSK.
  ///
  /// Result table:
  ///   - sender unknown → 200 (idempotent: we already aren't paired)
  ///   - HMAC mismatch  → 401 (don't leak which check failed)
  ///   - HMAC ok        → 200 + remove the local PairedDevice + emit
  ///                       a [ForgetEvent] so the UI can surface a toast
  Future<Response> _handlePeerForgotYou(Request request) async {
    final raw = await _readBodyCapped(request, _maxJsonBodyBytes);
    if (raw == null) {
      _log('peer-forgot-you reject: body exceeds $_maxJsonBodyBytes bytes');
      return Response(413);
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _log('peer-forgot-you reject: malformed JSON');
      return Response.badRequest();
    }
    String senderId;
    String signatureBase64;
    try {
      senderId = j['senderId'] as String;
      signatureBase64 = j['signature'] as String;
    } catch (_) {
      _log('peer-forgot-you reject: missing fields');
      return Response.badRequest();
    }
    final verifier = _verifier!;
    final paired = await verifier.repository.get(senderId);
    if (paired == null) {
      // Already not paired with this device; treat as a no-op success.
      _log('peer-forgot-you no-op: $senderId not in paired store');
      return Response.ok('');
    }
    final ok = verifyPeerForgotYouSignature(
      psk: paired.psk,
      senderId: senderId,
      providedBase64: signatureBase64,
    );
    if (!ok) {
      _log('peer-forgot-you reject: bad signature from $senderId');
      return Response.unauthorized('');
    }
    // HMAC succeeded → cache the source IP just like /upload does, then
    // hand off to ForgetService.
    if (_peerCache != null) {
      final host = _readRemoteHost(request);
      if (host != null) {
        await _peerCache.cacheAddress(
          deviceId: paired.deviceId,
          host: host,
          port: TransportProtocol.defaultPort,
          displayName: paired.displayName,
        );
      }
    }
    await _forget!.recordRemoteForgot(paired);
    _log('peer-forgot-you accepted from ${paired.deviceId} '
        '(${paired.displayName})');
    return Response.ok('');
  }

  /// Audit #8: read a request body into a String but refuse to buffer —
  /// or even read — more than [maxBytes]. Returns the decoded string, or
  /// `null` when the body is too large (caller should answer 413).
  ///
  /// Two independent guards, both rejecting EARLY (we never read a whole
  /// oversized body just to discard it — that would itself be a DoS):
  ///   1. Declared length — when `request.contentLength` is present and
  ///      already over the cap, bail without reading a byte.
  ///   2. Actual stream — a chunked request can omit or forge
  ///      contentLength, so we tally bytes as they arrive and return the
  ///      moment the running total would pass the cap. Returning from the
  ///      `await for` cancels the body subscription, so we stop reading.
  ///
  /// Rejecting mid-stream means an oversized sender may see a connection
  /// reset rather than a clean 413 — acceptable for an abusive/oversized
  /// request, and far better than reading gigabytes into the process.
  /// Decoding mirrors shelf's [Request.readAsString] default (UTF-8).
  static Future<String?> _readBodyCapped(Request request, int maxBytes) async {
    final declared = request.contentLength;
    if (declared != null && declared > maxBytes) return null;
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      if (bytes.length + chunk.length > maxBytes) return null;
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  /// Caches the inbound request's source IP onto [device] in
  /// [_peerCache]. No-op when the cache isn't wired or the connection
  /// info isn't available (in-memory tests).
  Future<void> _cacheSourceAddress({
    required Request request,
    required PairedDevice device,
  }) async {
    final cache = _peerCache;
    if (cache == null) return;
    final host = _readRemoteHost(request);
    if (host == null) return;
    await cache.cacheAddress(
      deviceId: device.deviceId,
      host: host,
      port: TransportProtocol.defaultPort,
      displayName: device.displayName,
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

  /// Slice 5.1.2: extract the requester's remote address as a URL-safe
  /// host string. shelf parks the underlying [HttpConnectionInfo] in
  /// the request context under a stable key. IPv6 addresses are wrapped
  /// in brackets so they parse correctly inside `https://$host:$port/`
  /// URIs. Returns null when shelf can't surface the connection info
  /// (in-memory tests, HTTP/2 paths) — the caller falls back to mDNS.
  static String? _readRemoteHost(Request request) {
    final info = request.context['shelf.io.connection_info']
        as HttpConnectionInfo?;
    if (info == null) return null;
    final addr = info.remoteAddress;
    if (addr.type == InternetAddressType.IPv6) {
      return '[${addr.address}]';
    }
    return addr.address;
  }

  /// Strip path separators, parent-directory traversal, ASCII control
  /// bytes, and Unicode bidi-formatting marks so a malicious sender
  /// can't (a) escape the downloads dir or (b) spoof a filename's
  /// rendered extension via right-to-left override.
  ///
  /// Slice 5.x.2.5: prior version dropped `\` `/` `..` only. A name
  /// containing U+202E (right-to-left override) renders as
  /// `reportexe.jpg` in Explorer / Finder, but the on-disk extension
  /// stays `.exe` — classic phishing surface on Windows. NUL /
  /// 0x00-0x1F also break filesystem APIs on most platforms (or worse
  /// — silently truncate at the NUL on POSIX paths handed to native
  /// code).
  static String _sanitizeFileName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/]'), '_');
    // Audit #24: characters that are illegal in a Win32 path AND never
    // valid in a portable filename. `:` is the dangerous one — a name
    // like `report.pdf:evil.exe` would otherwise resolve to an NTFS
    // Alternate Data Stream (invisible in Explorer, runnable via
    // wmic/start) and `C:foo` to a drive-relative write. The rest
    // (`< > " | ? *`) are rejected by CreateFile and are good hygiene
    // everywhere, so replace them unconditionally rather than gating on
    // Platform.isWindows.
    s = s.replaceAll(RegExp(r'[<>:"|?*]'), '_');
    // ASCII control chars (NUL through US, plus DEL).
    s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    // Unicode bidi controls: LRM, RLM, LRE, RLE, PDF, LRO, RLO, LRI,
    // RLI, FSI, PDI, ALM. The full set of "directional formatting
    // characters" per Unicode UAX #9. Escape-sequenced rather than
    // literal so this source file itself can be read safely.
    s = s.replaceAll(_bidiControlsPattern, '');
    s = s.replaceAll('..', '_');
    s = s.trim();
    // Audit #24: reserved DOS device names (CON, PRN, AUX, NUL, COM1-9,
    // LPT1-9) refer to devices, not files — opening `CON` or `NUL` even
    // with an extension (`CON.txt`) opens a device handle on Windows.
    // Windows compares the *stem* (text before the first dot), case-
    // insensitively, so guard on that and prefix `_` to make the name
    // ordinary. Done after illegal-char/bidi stripping so a disguised
    // `C:ON` collapses to `C_ON` (not reserved) first.
    final stem = s.split('.').first;
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false)
        .hasMatch(stem)) {
      s = '_$s';
    }
    // Windows refuses filenames that end in `.` or space — strip
    // trailing instances after the other transforms have settled.
    while (s.isNotEmpty && (s.endsWith('.') || s.endsWith(' '))) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) s = 'file';
    return s;
  }

  /// If `foo.txt` exists in [dir], returns `foo (1).txt`, then
  /// `foo (2).txt`, etc. Avoids clobbering existing downloads.
  ///
  /// Audit #11 (TOCTOU): the returned [File] is **atomically reserved**,
  /// not merely probed. A plain `exists()` check leaves a window between
  /// path selection and the later `openWrite()` (default `FileMode.write`
  /// = truncate) in which two concurrent uploads of the same sanitized
  /// name both see the candidate as free, resolve to the identical path,
  /// and the second clobbers the first. Instead we create each candidate
  /// with `exclusive: true` (O_EXCL): the create *is* the selection, so
  /// it fails the moment another upload has already claimed that name.
  /// The reserved file is empty; the caller's `openWrite()` then opens it
  /// (truncating an empty file is a no-op) and streams the body in.
  Future<File> _resolveUniqueDestination(Directory dir, String name) async {
    final first = File('${dir.path}${Platform.pathSeparator}$name');
    if (await _tryReserve(first)) return first;

    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    for (var i = 1; i < 10000; i++) {
      final candidate =
          File('${dir.path}${Platform.pathSeparator}$stem ($i)$ext');
      if (await _tryReserve(candidate)) return candidate;
    }
    // Extremely unlikely fallback — a random tag is collision-proof in
    // practice, but still reserve it exclusively for consistency.
    final fallback =
        File('${dir.path}${Platform.pathSeparator}$stem-${_uuid.v4()}$ext');
    await _tryReserve(fallback);
    return fallback;
  }

  /// Atomically claim [candidate] by creating it with `exclusive: true`
  /// (O_EXCL). Returns true when this call won the race and created the
  /// (empty) file; false when the name is already taken. A genuine
  /// filesystem error (permission denied, disk full, bad path) is
  /// rethrown so the upload fails fast instead of silently churning
  /// through every suffix.
  static Future<bool> _tryReserve(File candidate) async {
    try {
      await candidate.create(exclusive: true);
      return true;
    } on FileSystemException {
      // EEXIST is the expected collision; anything else (and we can't
      // portably read the OS errno) we disambiguate by re-checking
      // existence — a name that now exists was a real collision, retry
      // the next suffix; otherwise the create failed for another reason
      // and we must not mask it.
      if (await candidate.exists()) return false;
      rethrow;
    }
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
