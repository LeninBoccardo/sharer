import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mime/mime.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/home/dropped_file_sender.dart';

/// Captures the full [send] arguments so the test can inspect the built
/// payload + reopen factory (which the lighter RecordingTransferService does
/// not retain).
class _CapturingTransferService implements TransferService {
  final List<
      ({
        Peer peer,
        FilePayload file,
        Stream<List<int>> Function()? reopen,
      })> calls = [];
  bool throwOnSend = false;
  int _seq = 0;

  @override
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  }) async {
    if (throwOnSend) throw StateError('send blew up');
    calls.add((peer: peer, file: file, reopen: reopen));
    return Transfer(
      id: 'tx-${_seq++}',
      peerId: peer.id,
      peerName: peer.name,
      fileName: file.fileName,
      totalBytes: file.sizeBytes,
      direction: TransferDirection.sending,
      startedAt: DateTime.utc(2026, 6, 2),
    );
  }

  @override
  Stream<List<Transfer>> watchAll() => const Stream.empty();
  @override
  Future<void> cancel(String transferId) async {}
  @override
  Future<void> retry(String transferId) async {}
}

Peer _peer() => Peer(
      id: 'a',
      name: 'Alpha',
      host: '10.0.0.5',
      port: 8080,
      lastSeen: DateTime.utc(2026, 6, 2),
    );

Future<List<int>> _drain(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sharer_drop'));
  tearDown(() => dir.deleteSync(recursive: true));

  DroppedFileSpec writeSpec(String name, String content) {
    final file = File('${dir.path}/$name')..writeAsStringSync(content);
    return DroppedFileSpec(
      path: file.path,
      name: name,
      size: content.length,
    );
  }

  test('streams a real dropped file and sends it once', () async {
    final service = _CapturingTransferService();
    final spec = writeSpec('drop.txt', 'drag-and-drop');

    final result = await sendDroppedFiles(
      service: service,
      peer: _peer(),
      files: [spec],
    );

    expect(result.queued, 1);
    expect(result.skipped, 0);
    expect(result.started, hasLength(1));
    expect(service.calls, hasLength(1));

    final payload = service.calls.single.file;
    expect(payload.fileName, 'drop.txt');
    expect(payload.sizeBytes, spec.size);
    expect(payload.mimeType, lookupMimeType('drop.txt'));
    // The bytes stream is File.openRead() — draining it yields the contents,
    // proving it is not eagerly buffered.
    expect(String.fromCharCodes(await _drain(payload.bytes)), 'drag-and-drop');
  });

  test('reopen factory re-opens from zero for retry', () async {
    final service = _CapturingTransferService();
    writeSpec('again.bin', 'payload-bytes');

    await sendDroppedFiles(
      service: service,
      peer: _peer(),
      files: [writeSpec('again.bin', 'payload-bytes')],
    );

    final reopen = service.calls.single.reopen;
    expect(reopen, isNotNull);
    // Two independent drains both yield the full contents (retryable).
    expect(String.fromCharCodes(await _drain(reopen!())), 'payload-bytes');
    expect(String.fromCharCodes(await _drain(reopen())), 'payload-bytes');
  });

  test('a spec whose path does not exist is skipped, never sent', () async {
    final service = _CapturingTransferService();
    final ghost = DroppedFileSpec(
      path: '${dir.path}/missing.txt',
      name: 'missing.txt',
      size: 10,
    );

    final result = await sendDroppedFiles(
      service: service,
      peer: _peer(),
      files: [ghost],
    );

    expect(result.queued, 0);
    expect(result.skipped, 1);
    expect(result.started, isEmpty);
    expect(service.calls, isEmpty);
  });

  test('a mixed batch sends the good file and skips the missing one',
      () async {
    final service = _CapturingTransferService();
    final good = writeSpec('good.txt', 'ok');
    final missing = DroppedFileSpec(
      path: '${dir.path}/gone.txt',
      name: 'gone.txt',
      size: 3,
    );

    final result = await sendDroppedFiles(
      service: service,
      peer: _peer(),
      files: [good, missing],
    );

    expect(result.queued, 1);
    expect(result.skipped, 1);
    expect(service.calls.single.file.fileName, 'good.txt');
  });

  test('a send that throws is counted skipped and never aborts the batch',
      () async {
    final service = _CapturingTransferService()..throwOnSend = true;
    final spec = writeSpec('boom.txt', 'x');

    final result = await sendDroppedFiles(
      service: service,
      peer: _peer(),
      files: [spec],
    );

    expect(result.queued, 0);
    expect(result.skipped, 1);
    expect(result.started, isEmpty);
  });
}
