import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/device_identity.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/repositories/device_identity_repository.dart';
import '../../domain/repositories/transfer_service.dart';
import 'http_file_client.dart';
import 'http_file_server.dart';
import 'incoming_event.dart';

/// Aggregates outgoing sends and incoming receives into a single
/// reactive list of [Transfer] objects. The UI watches one stream and
/// gets both directions in chronological order.
class TransferServiceImpl implements TransferService {
  static const _logName = 'sharer.transport.service';
  static const _maxKeptTerminal = 50;

  final HttpFileClient _client;
  final HttpFileServer _server;
  final DeviceIdentityRepository _identityRepo;
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
    Uuid? uuid,
  })  : _client = client,
        _server = server,
        _identityRepo = identityRepo,
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
    final identity = await _identityRepo.get();
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
    unawaited(_runUpload(transfer, peer, file, identity));
    return transfer;
  }

  Future<void> _runUpload(
    Transfer initial,
    Peer peer,
    FilePayload file,
    DeviceIdentity sender,
  ) async {
    try {
      final result = await _client.upload(
        host: peer.host!,
        port: peer.port!,
        file: file,
        sender: sender,
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
