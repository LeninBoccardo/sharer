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
  final _controller = StreamController<List<Transfer>>.broadcast();
  StreamSubscription<IncomingEvent>? _incomingSub;

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
    );
    _put(transfer);

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

  Future<void> _runUpload(
    Transfer initial,
    Peer peer,
    FilePayload file,
    DeviceIdentity sender,
    PairedDevice? paired,
  ) async {
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
    try {
      final result = await _client.upload(
        host: host,
        port: port,
        file: file,
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
      _log('Send done id=${initial.id} bytes=${result.bytesSent}');
    } catch (e, st) {
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
    }
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
    for (final e in terminals.take(toDrop)) {
      _byId.remove(e.key);
    }
  }

  /// Most-recent first.
  List<Transfer> _snapshot() {
    final list = _byId.values.toList();
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
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
