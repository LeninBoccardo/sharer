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
import '../security/pairing_service.dart';
import '../storage/downloads_locator.dart';
import 'incoming_event.dart';
import 'transport_protocol.dart';

/// Receiving side of the file-transfer transport. shelf-based HTTP
/// server, gated on trust state via the same desired-state reconciler
/// pattern used by [MdnsPeerDiscovery] (see slice 2.5). Streams uploads
/// to disk — never buffers a whole file in memory.
class HttpFileServer {
  static const _logName = 'sharer.transport.server';

  /// Emit a progress event at most once per ~256 KB to keep UI rebuilds
  /// reasonable on large transfers.
  static const _progressThresholdBytes = 256 * 1024;

  final DownloadsLocator _downloads;
  final Stream<bool> _isTrusted;
  final HmacVerifier? _verifier;
  final PairingService? _pairing;
  final int _port;
  final Uuid _uuid;

  final _events = StreamController<IncomingEvent>.broadcast();
  HttpServer? _httpServer;
  StreamSubscription<bool>? _trustSub;

  bool _started = false;
  bool _desiredEnabled = false;
  bool _reconcileInFlight = false;
  bool _reconcileQueued = false;

  HttpFileServer({
    required DownloadsLocator downloads,
    required Stream<bool> isTrusted,
    HmacVerifier? verifier,
    PairingService? pairing,
    int port = TransportProtocol.defaultPort,
    Uuid? uuid,
  })  : _downloads = downloads,
        _isTrusted = isTrusted,
        _verifier = verifier,
        _pairing = pairing,
        _port = port,
        _uuid = uuid ?? const Uuid();

  Stream<IncomingEvent> get events => _events.stream;

  /// Actual bound port (useful in tests when [_port] is 0).
  int? get boundPort => _httpServer?.port;

  bool get isRunning => _httpServer != null;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _log('Started — reacting to trust state');
    _trustSub = _isTrusted.listen(_onTrustChange);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _log('Stopping');
    await _trustSub?.cancel();
    _trustSub = null;
    _desiredEnabled = false;
    await _runReconcileToCompletion();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  // ---- Reconciler (mirrors MdnsPeerDiscovery; see slice 2.5 rules) ----

  void _onTrustChange(bool trusted) {
    _log('Trust → $trusted');
    _desiredEnabled = trusted;
    if (_reconcileInFlight) {
      _reconcileQueued = true;
      return;
    }
    unawaited(_runReconcileToCompletion());
  }

  Future<void> _runReconcileToCompletion() async {
    if (_reconcileInFlight) {
      _reconcileQueued = true;
      while (_reconcileInFlight) {
        await Future<void>.delayed(Duration.zero);
      }
      return;
    }
    _reconcileInFlight = true;
    try {
      do {
        _reconcileQueued = false;
        await _applyDesiredState();
      } while (_reconcileQueued);
    } finally {
      _reconcileInFlight = false;
    }
  }

  Future<void> _applyDesiredState() async {
    final shouldRun = _desiredEnabled && _started;
    final isRunningNow = _httpServer != null;
    if (shouldRun == isRunningNow) return;
    if (shouldRun) {
      await _bind();
    } else {
      await _unbind();
    }
  }

  Future<void> _bind() async {
    if (_httpServer != null) return;
    _log('Binding HTTP server on port $_port');
    final router = Router();
    router.post(TransportProtocol.uploadPath, _handleUpload);
    if (_pairing != null) {
      router.post(TransportProtocol.pairPath, _handlePair);
    }
    final handler = const Pipeline().addHandler(router.call);
    try {
      _httpServer = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
      _log('HTTP server listening on ${_httpServer!.address.address}:${_httpServer!.port}');
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
    _log('Unbinding HTTP server');
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

  Future<Response> _handlePair(Request request) async {
    final pairing = _pairing!;
    final headers = request.headers;
    final responderId = headers[TransportProtocol.headerDeviceId];
    final responderName =
        _decodeHeader(headers[TransportProtocol.headerDeviceName]) ??
            'Unknown device';
    final offerId = headers[TransportProtocol.headerPairOfferId];
    final code = headers[TransportProtocol.headerPairCode];
    final signature = headers[TransportProtocol.headerSignature];

    if (responderId == null ||
        responderId.isEmpty ||
        offerId == null ||
        offerId.isEmpty ||
        code == null ||
        code.isEmpty ||
        signature == null ||
        signature.isEmpty) {
      _log('Reject pair: missing required headers');
      await request.read().drain<void>();
      return Response.unauthorized('');
    }

    final paired = await pairing.completePair(
      offerId: offerId,
      numericCode: code,
      responderId: responderId,
      responderName: responderName,
      signature: signature,
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
