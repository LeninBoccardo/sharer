import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/paired_device.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/paired_devices_repository.dart';
import '../../domain/repositories/peer_cache_repository.dart';
import '../../domain/repositories/transfer_service.dart';
import '../security/forget_service.dart';
import 'http_file_client.dart';
import 'http_file_server.dart';
import 'incoming_event.dart';
import 'transport_protocol.dart';

/// Aggregates outgoing sends and incoming receives into a single
/// reactive list of [Transfer] objects. The UI watches one stream and
/// gets both directions in chronological order.
class TransferServiceImpl implements TransferService {
  static const _logName = 'sharer.transport.service';
  static const _maxKeptTerminal = 50;

  /// Audit #38: only prefer a cached peer address over the live
  /// mDNS-resolved peer.host while the cached entry is reasonably fresh.
  /// Past this, a DHCP lease change / subnet move makes the cached IP
  /// more likely wrong than right, so we trust fresh discovery instead.
  static const _cachedAddressFreshFor = Duration(hours: 12);

  final HttpFileClient _client;
  final HttpFileServer _server;
  final DeviceIdentityRepository _identityRepo;
  final PairedDevicesRepository _pairedRepo;
  final PeerCacheRepository? _peerCache;
  final ForgetService? _forget;
  final Uuid _uuid;

  /// Insertion-ordered map; iteration is most-recently-added first when
  /// reversed. Bounded so completed/failed transfers don't grow without
  /// bound across a long-running session.
  final Map<String, Transfer> _byId = {};

  /// Cached most-recent-first ordering of [_byId] keys. The display order
  /// (descending by startedAt) only changes when the key-set changes — a
  /// new transfer is inserted or terminal entries are evicted — never on a
  /// value-only progress/status update (startedAt is immutable through
  /// copyWith). New transfers always carry startedAt = DateTime.now(), the
  /// latest, so prepending here preserves the descending order without a
  /// per-emit sort (audit #51).
  final List<String> _orderedIds = [];
  final _controller = StreamController<List<Transfer>>.broadcast();
  StreamSubscription<IncomingEvent>? _incomingSub;

  /// Audit #28: per-outgoing-transfer cancel signal. Present only while an
  /// upload is in flight; completing it aborts the upload stream and the
  /// catch in [_runUpload] then records [TransferStatus.cancelled]
  /// (rather than `failed`). The entry is removed when the upload settles.
  final Map<String, Completer<void>> _cancelSignals = {};

  /// Phase 4 (retry): everything needed to re-run a failed upload from
  /// zero, keyed by transferId. Populated in [send] only when a `reopen`
  /// factory was supplied; consulted by [retry]; dropped on a
  /// completed/cancelled settle and on terminal eviction (a completed or
  /// cancelled source may be deleted, so it must never be re-opened). A
  /// FAILED settle keeps the spec so the user can retry.
  final Map<String, _RetrySpec> _retry = {};

  TransferServiceImpl({
    required HttpFileClient client,
    required HttpFileServer server,
    required DeviceIdentityRepository identityRepo,
    required PairedDevicesRepository pairedRepo,
    PeerCacheRepository? peerCache,
    ForgetService? forget,
    Uuid? uuid,
  })  : _client = client,
        _server = server,
        _identityRepo = identityRepo,
        _pairedRepo = pairedRepo,
        _peerCache = peerCache,
        _forget = forget,
        _uuid = uuid ?? const Uuid() {
    _incomingSub = _server.events.listen(_onIncoming);
  }

  @override
  Stream<List<Transfer>> watchAll() async* {
    yield _snapshot();
    yield* _controller.stream;
  }

  @override
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  }) async {
    if (!peer.isReachable) {
      throw StateError('Peer ${peer.id} is not reachable (no host/port).');
    }
    // Audit #50: the identity load and the paired-device lookup are
    // independent storage reads, so run them concurrently to shave a
    // round-trip off the send hot path. Both futures are awaited
    // together via the records `.wait` extension, so neither is left
    // orphaned; a failure in either still propagates out of send()
    // before any Transfer is created.
    //
    // The `paired` lookup decides signing + cert-pinning: when we have
    // a PairedDevice entry for the peer we sign + pin against its
    // pinned cert fingerprint. Unpaired sends — only possible in slice
    // ≤ 4.3 mode where the trust-network gate was the fallback — go out
    // unsigned and unpinned. Slice 4.4 + 5.1 production servers reject
    // both.
    final (identity, paired) = await (
      _identityRepo.get(),
      _pairedRepo.get(peer.id),
    ).wait;
    final transfer = Transfer(
      id: _uuid.v4(),
      peerId: peer.id,
      peerName: peer.name,
      fileName: file.fileName,
      totalBytes: file.sizeBytes,
      direction: TransferDirection.sending,
      startedAt: DateTime.now(),
      status: TransferStatus.inProgress,
      // Phase 4 (retry): only retryable if the caller gave us a way to
      // re-open the source. The first upload still consumes `file`.
      canRetry: reopen != null,
    );
    _put(transfer);

    if (reopen != null) {
      _retry[transfer.id] = _RetrySpec(
        peer: peer,
        identity: identity,
        paired: paired,
        // Build a FRESH streamed FilePayload each retry — never buffers.
        rebuild: () => FilePayload(
          fileName: file.fileName,
          sizeBytes: file.sizeBytes,
          mimeType: file.mimeType,
          bytes: reopen(),
        ),
      );
    }

    // Fire-and-forget the actual upload; progress + completion arrive
    // via the watchAll stream so the caller's Future resolving immediately
    // doesn't block the UI.
    unawaited(_runUpload(
      transfer,
      peer,
      file,
      identity,
      paired,
    ));
    return transfer;
  }

  @override
  Future<void> cancel(String transferId) async {
    final current = _byId[transferId];
    // Idempotent: ignore unknown ids, already-terminal transfers, and
    // incoming transfers (those are driven by HttpFileServer events, not
    // by _runUpload, so there is no outgoing stream to abort here).
    if (current == null ||
        current.isTerminal ||
        current.direction != TransferDirection.sending) {
      return;
    }
    final signal = _cancelSignals[transferId];
    if (signal == null || signal.isCompleted) {
      // No in-flight upload (e.g. it settled between the lookup and now).
      return;
    }
    _log('Cancel requested id=$transferId');
    signal.complete();
  }

  @override
  Future<void> retry(String transferId) async {
    final current = _byId[transferId];
    final spec = _retry[transferId];
    // Idempotent: only a known, failed, outgoing transfer that still has a
    // retained re-open source can be retried.
    if (current == null ||
        current.status != TransferStatus.failed ||
        current.direction != TransferDirection.sending ||
        spec == null) {
      return;
    }
    _log('Retry requested id=$transferId');
    // Reuse the same id so watchAll reflects the failed -> inProgress ->
    // completed transition in place (the UI tile/screen updates, no new
    // row). bytesTransferred resets to 0 — v1 retries from zero, not a
    // resume. (errorMessage is left set but is only shown in the failed
    // state, so it is invisible while inProgress/completed.)
    final refreshed = current.copyWith(
      status: TransferStatus.inProgress,
      bytesTransferred: 0,
    );
    _put(refreshed);
    unawaited(_runUpload(
      refreshed,
      spec.peer,
      spec.rebuild(),
      spec.identity,
      spec.paired,
    ));
  }

  Future<void> _runUpload(
    Transfer initial,
    Peer peer,
    FilePayload file,
    DeviceIdentity sender,
    PairedDevice? paired,
  ) async {
    final cancelSignal = Completer<void>();
    _cancelSignals[initial.id] = cancelSignal;
    final recipientPsk = paired?.psk;
    final recipientCertFingerprint = paired?.certFingerprint;
    // Slice 5.4: prefer the IP we cached from any HMAC-verified inbound
    // request (`/upload`, `/pair-finalize`, `/peer-forgot-you`). Bonsoir
    // can hand us a stale or wrong-interface address (e.g. on Realme
    // overwriting peer.host with the device's own IP — see
    // reference_bonsoir_ip_flake.md). Fall back to peer.host when we
    // have no cached address yet.
    String host = peer.host!;
    int port = peer.port!;
    if (_peerCache != null) {
      final cached =
          await _peerCache.getById(peer.id, freshFor: _cachedAddressFreshFor);
      if (cached?.host != null && cached?.port != null) {
        host = cached!.host!;
        port = cached.port!;
        if (host != peer.host) {
          _log('id=${initial.id} prefer cached host=$host:$port over '
              'mDNS=${peer.host}:${peer.port}');
        }
      }
    }
    // Audit #28: wrap the payload stream so a cancel signal aborts the
    // in-flight upload. When [cancelSignal] completes, the wrapped stream
    // emits an error, which propagates out of HttpFileClient.upload's
    // `request.addStream` and tears down the connection. The catch below
    // then records `cancelled` instead of `failed`.
    final cancellableFile = FilePayload(
      fileName: file.fileName,
      sizeBytes: file.sizeBytes,
      mimeType: file.mimeType,
      bytes: _abortable(file.bytes, cancelSignal.future),
    );
    try {
      final result = await _client.upload(
        host: host,
        port: port,
        file: cancellableFile,
        sender: sender,
        // Audit #30: bind the recipient's own deviceId into the HMAC.
        // peer.id is the PairedDevice.deviceId we send to; the receiver
        // reconstructs the canonical with its own local id.
        recipientDeviceId: peer.id,
        recipientPsk: recipientPsk,
        recipientCertFingerprint: recipientCertFingerprint,
        onProgress: (bytes) {
          final current = _byId[initial.id];
          if (current == null) return;
          // Throttle to ~256 KB increments to keep stream churn low.
          if (bytes - current.bytesTransferred < 256 * 1024 &&
              bytes != current.totalBytes) {
            return;
          }
          _put(current.copyWith(bytesTransferred: bytes));
        },
      );
      final current = _byId[initial.id] ?? initial;
      _put(current.copyWith(
        bytesTransferred: result.bytesSent,
        status: TransferStatus.completed,
        completedAt: DateTime.now(),
        savedPath: result.savedPath,
      ));
      // Completed: the source is done; drop the retry spec so a deleted
      // source can never be re-opened.
      _retry.remove(initial.id);
      _log('Send done id=${initial.id} bytes=${result.bytesSent}');
    } catch (e, st) {
      // Audit #28: a completed cancel signal means the user aborted this
      // upload — record `cancelled`, not `failed`, and skip the reactive
      // forget path (a torn-down stream is not a peer rejection).
      if (cancelSignal.isCompleted) {
        final current = _byId[initial.id] ?? initial;
        _put(current.copyWith(
          status: TransferStatus.cancelled,
          completedAt: DateTime.now(),
        ));
        // Cancelled: the share path deletes the cached source on a
        // cancelled settle, so drop the retry spec — re-opening a deleted
        // file would just fail.
        _retry.remove(initial.id);
        _log('Send cancelled id=${initial.id}');
        return;
      }
      developer.log('Send failed', error: e, stackTrace: st, name: _logName);
      // Slice 5.4 reactive forget: a 401 from a peer that's in our
      // PairedDevices store means they removed us. Drop the local
      // entry and emit a forget event so the user gets a notification.
      // Audit #1: only a 403 + X-Sharer-Reason: unknown-sender means the
      // peer dropped us from their paired store. A bare 401 is a
      // transient signing failure (clock skew, nonce replay, malformed
      // headers) and must NOT silently unpair a still-valid peer.
      if (e is UploadStatusException &&
          e.statusCode == 403 &&
          e.reason == TransportProtocol.reasonUnknownSender &&
          paired != null &&
          _forget != null) {
        unawaited(_forget.recordReactive401(paired));
      }
      final current = _byId[initial.id] ?? initial;
      _put(current.copyWith(
        status: TransferStatus.failed,
        completedAt: DateTime.now(),
        errorMessage: e.toString(),
      ));
      _log('Send failed id=${initial.id}: $e');
    } finally {
      // Audit #28: the upload has settled (done / failed / cancelled) —
      // drop the cancel signal so a late cancel() call is a no-op and the
      // map doesn't leak across a long session.
      _cancelSignals.remove(initial.id);
    }
  }

  /// Audit #28: forwards [source] chunks until [cancel] completes, at
  /// which point the returned stream emits an error and stops — aborting
  /// any consumer (here, the upload's `request.addStream`). The error
  /// type is internal; the caller distinguishes cancel from a real
  /// failure via the cancel Completer, not by inspecting this error.
  Stream<List<int>> _abortable(
    Stream<List<int>> source,
    Future<void> cancel,
  ) {
    final out = StreamController<List<int>>();
    var cancelled = false;
    late StreamSubscription<List<int>> sub;

    Future<void> stop() async {
      await sub.cancel();
      if (!out.isClosed) await out.close();
    }

    cancel.then((_) {
      if (cancelled || out.isClosed) return;
      cancelled = true;
      out.addError(const _UploadCancelled());
      stop();
    });

    sub = source.listen(
      (chunk) {
        if (!cancelled && !out.isClosed) out.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!cancelled && !out.isClosed) out.addError(e, st);
      },
      onDone: () {
        if (!cancelled && !out.isClosed) out.close();
      },
      cancelOnError: true,
    );
    // Pausing the upload sink propagates back-pressure to the source.
    out.onPause = sub.pause;
    out.onResume = sub.resume;
    out.onCancel = sub.cancel;
    return out.stream;
  }

  void _onIncoming(IncomingEvent event) {
    switch (event) {
      case IncomingStarted():
        _put(Transfer(
          id: event.id,
          peerId: event.senderId,
          peerName: event.senderName,
          fileName: event.fileName,
          totalBytes: event.totalBytes,
          direction: TransferDirection.receiving,
          startedAt: DateTime.now(),
          status: TransferStatus.inProgress,
        ));
      case IncomingProgress():
        final current = _byId[event.id];
        if (current == null) return;
        _put(current.copyWith(bytesTransferred: event.bytesReceived));
      case IncomingCompleted():
        final current = _byId[event.id];
        if (current == null) return;
        _put(current.copyWith(
          status: TransferStatus.completed,
          completedAt: DateTime.now(),
          savedPath: event.savedPath,
          bytesTransferred:
              current.totalBytes > 0 ? current.totalBytes : current.bytesTransferred,
        ));
      case IncomingFailed():
        final current = _byId[event.id];
        if (current == null) return;
        _put(current.copyWith(
          status: TransferStatus.failed,
          completedAt: DateTime.now(),
          errorMessage: event.error,
        ));
    }
  }

  void _put(Transfer t) {
    // A brand-new id changes the key-set, so it (and only it) updates the
    // cached ordering. New transfers carry the latest startedAt, so
    // most-recent-first means prepend.
    if (!_byId.containsKey(t.id)) {
      _orderedIds.insert(0, t.id);
    }
    _byId[t.id] = t;
    _evictOldTerminals();
    _controller.add(_snapshot());
  }

  void _evictOldTerminals() {
    final terminals = _byId.entries.where((e) => e.value.isTerminal).toList();
    if (terminals.length <= _maxKeptTerminal) return;
    // Drop the oldest terminal entries (by completedAt or startedAt).
    terminals.sort((a, b) {
      final ta = a.value.completedAt ?? a.value.startedAt;
      final tb = b.value.completedAt ?? b.value.startedAt;
      return ta.compareTo(tb);
    });
    final toDrop = terminals.length - _maxKeptTerminal;
    final dropped = <String>{};
    for (final e in terminals.take(toDrop)) {
      _byId.remove(e.key);
      // Drop any retry spec for an evicted terminal so a long session
      // can't leak re-open closures past the bounded transfer list.
      _retry.remove(e.key);
      dropped.add(e.key);
    }
    _orderedIds.removeWhere(dropped.contains);
  }

  /// Most-recent first. Built from the cached [_orderedIds] order so there
  /// is no per-emit sort — the order is maintained incrementally as the
  /// key-set changes in [_put] / [_evictOldTerminals] (audit #51).
  List<Transfer> _snapshot() {
    final list = <Transfer>[];
    for (final id in _orderedIds) {
      final t = _byId[id];
      if (t != null) list.add(t);
    }
    return List.unmodifiable(list);
  }

  Future<void> dispose() async {
    await _incomingSub?.cancel();
    _incomingSub = null;
    await _controller.close();
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}

/// Audit #28: marker error emitted into the upload stream when a transfer
/// is cancelled. Not surfaced to callers — the cancel Completer is the
/// source of truth; this just unwinds `request.addStream`.
class _UploadCancelled implements Exception {
  const _UploadCancelled();
  @override
  String toString() => 'upload cancelled';
}

/// Phase 4 (retry): the retained state needed to re-run a failed upload.
/// [rebuild] returns a FRESH streamed [FilePayload] (re-opening the source)
/// on every call, so a retry never buffers the file. The identity + paired
/// device are captured at send() time so a retry signs/pins identically.
class _RetrySpec {
  _RetrySpec({
    required this.peer,
    required this.rebuild,
    required this.identity,
    required this.paired,
  });

  final Peer peer;
  final FilePayload Function() rebuild;
  final DeviceIdentity identity;
  final PairedDevice? paired;
}
