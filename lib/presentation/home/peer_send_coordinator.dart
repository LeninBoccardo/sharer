import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../app/providers.dart';
import '../../data/share/incoming_share_service.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/repositories/transfer_service.dart';
import '../share/pending_shares_controller.dart';

/// Pure-presentation send helper shared by the single-tap path and the
/// multi-peer fan-out — two real callers, so the hoist out of _PeerTile is
/// justified (not premature). Holds NO state; every call takes the target
/// peer(s). Returns the started transfer ids so the caller can scope the
/// transfer screen.
class PeerSendCoordinator {
  const PeerSendCoordinator(this.ref);

  final WidgetRef ref;

  /// Single-peer send (the existing 1-tap behaviour): route pending shares to
  /// [peer], else open the file picker.
  Future<Set<String>> sendToPeer(BuildContext context, Peer peer) async {
    final pending = ref.read(pendingSharesProvider).value;
    if (pending != null && pending.isNotEmpty) {
      return _sendPending(context, peer, pending.files);
    }
    return _pickAndSend(context, peer);
  }

  /// Multi-peer fan-out: pending shares (or a single file-picker pass) sent to
  /// every peer from a FRESH per-peer stream. Returns the union of ids.
  Future<Set<String>> sendToPeers(
    BuildContext context,
    List<Peer> peers,
  ) async {
    if (peers.isEmpty) return const <String>{};
    final pending = ref.read(pendingSharesProvider).value;
    if (pending != null && pending.isNotEmpty) {
      return _fanOutPending(context, peers, pending.files);
    }
    return _fanOutPicked(context, peers);
  }

  // ---- single-peer (moved verbatim from _PeerTile, parameterised by peer) --

  Future<Set<String>> _sendPending(
    BuildContext context,
    Peer peer,
    List<IncomingSharedFile> files,
  ) async {
    final transferService = ref.read(transferServiceProvider);
    final pendingController = ref.read(pendingSharesControllerProvider);
    var queued = 0;
    var skipped = 0;
    final started = <String>{};
    final deleteImmediately = <String>[];
    for (final shared in files) {
      try {
        final file = File(shared.path);
        if (!await file.exists()) {
          deleteImmediately.add(shared.path);
          skipped++;
          continue;
        }
        final payload = FilePayload(
          fileName: shared.name,
          sizeBytes: shared.size,
          bytes: file.openRead(),
          mimeType: shared.mimeType ?? lookupMimeType(shared.name),
        );
        final transfer = await transferService.send(
          peer: peer,
          file: payload,
          reopen: () => File(shared.path).openRead(),
        );
        started.add(transfer.id);
        unawaited(
          _deleteWhenDrained(transferService, pendingController, {
            transfer.id,
          }, shared.path),
        );
        queued++;
      } catch (_) {
        deleteImmediately.add(shared.path);
        skipped++;
      }
    }
    pendingController.clearState();
    await pendingController.deleteFiles(deleteImmediately);
    if (!context.mounted) return started;
    if (queued == 0) {
      _toast(context, 'Could not send shared files.');
    } else if (queued == 1 && skipped == 0) {
      _toast(context, 'Sending ${files.first.name} → ${peer.name}…');
    } else {
      _toast(
        context,
        'Sending $queued file${queued == 1 ? '' : 's'} → ${peer.name}'
        '${skipped > 0 ? ' ($skipped skipped)' : ''}…',
      );
    }
    return started;
  }

  Future<Set<String>> _pickAndSend(BuildContext context, Peer peer) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        withReadStream: true,
        allowMultiple: true,
      );
    } catch (e) {
      if (!context.mounted) return const <String>{};
      _toast(context, 'File picker error: $e');
      return const <String>{};
    }
    if (result == null || result.files.isEmpty) return const <String>{};

    final transferService = ref.read(transferServiceProvider);
    var queued = 0;
    var skipped = 0;
    final started = <String>{};
    for (final picked in result.files) {
      final stream = picked.readStream;
      if (stream == null) {
        skipped++;
        continue;
      }
      final payload = FilePayload(
        fileName: picked.name,
        sizeBytes: picked.size,
        bytes: stream,
        mimeType: lookupMimeType(picked.name),
      );
      final path = picked.path;
      Stream<List<int>> Function()? reopen;
      if (path != null) {
        reopen = () => File(path).openRead();
      }
      try {
        final transfer = await transferService.send(
          peer: peer,
          file: payload,
          reopen: reopen,
        );
        started.add(transfer.id);
        queued++;
      } catch (_) {
        skipped++;
      }
    }
    if (!context.mounted) return started;
    if (queued == 0) {
      _toast(context, 'No files could be sent.');
    } else if (queued == 1 && skipped == 0) {
      _toast(context, 'Sending ${result.files.first.name} → ${peer.name}…');
    } else {
      _toast(
        context,
        'Sending $queued file${queued == 1 ? '' : 's'} → ${peer.name}'
        '${skipped > 0 ? ' ($skipped skipped)' : ''}…',
      );
    }
    return started;
  }

  // ---- multi-peer fan-out ------------------------------------------------

  Future<Set<String>> _fanOutPicked(
    BuildContext context,
    List<Peer> peers,
  ) async {
    final FilePickerResult? result;
    try {
      // withReadStream:false — the one-shot readStream can't be reused across
      // peers, so each peer re-opens File(path) instead.
      result = await FilePicker.pickFiles(allowMultiple: true);
    } catch (e) {
      if (!context.mounted) return const <String>{};
      _toast(context, 'File picker error: $e');
      return const <String>{};
    }
    if (result == null || result.files.isEmpty) return const <String>{};

    final transferService = ref.read(transferServiceProvider);
    final started = <String>{};
    var skippedFiles = 0;
    for (final picked in result.files) {
      final path = picked.path;
      if (path == null) {
        // A path-less pick (web) can't be re-streamed per peer.
        skippedFiles++;
        continue;
      }
      for (final peer in peers) {
        try {
          final transfer = await transferService.send(
            peer: peer,
            file: FilePayload(
              fileName: picked.name,
              sizeBytes: picked.size,
              bytes: File(path).openRead(),
              mimeType: lookupMimeType(picked.name),
            ),
            reopen: () => File(path).openRead(),
          );
          started.add(transfer.id);
        } catch (_) {
          /* per-peer failure surfaces on its transfer card */
        }
      }
    }
    if (!context.mounted) return started;
    _toast(
      context,
      started.isEmpty
          ? 'No files could be sent.'
          : 'Sending to ${peers.length} device${peers.length == 1 ? '' : 's'}…'
                '${skippedFiles > 0 ? ' ($skippedFiles skipped)' : ''}',
    );
    return started;
  }

  Future<Set<String>> _fanOutPending(
    BuildContext context,
    List<Peer> peers,
    List<IncomingSharedFile> files,
  ) async {
    final transferService = ref.read(transferServiceProvider);
    final pendingController = ref.read(pendingSharesControllerProvider);
    final started = <String>{};
    final deleteImmediately = <String>[];
    for (final shared in files) {
      if (!await File(shared.path).exists()) {
        deleteImmediately.add(shared.path);
        continue;
      }
      final perFileIds = <String>{};
      for (final peer in peers) {
        try {
          final transfer = await transferService.send(
            peer: peer,
            file: FilePayload(
              fileName: shared.name,
              sizeBytes: shared.size,
              bytes: File(shared.path).openRead(),
              mimeType: shared.mimeType ?? lookupMimeType(shared.name),
            ),
            reopen: () => File(shared.path).openRead(),
          );
          perFileIds.add(transfer.id);
        } catch (_) {
          /* per-peer failure surfaces on its transfer card */
        }
      }
      if (perFileIds.isEmpty) {
        deleteImmediately.add(shared.path);
      } else {
        started.addAll(perFileIds);
        // Delete the cache file only after EVERY peer's transfer for this
        // file is terminal — else peer #2 finds it deleted by peer #1.
        unawaited(
          _deleteWhenDrained(
            transferService,
            pendingController,
            perFileIds,
            shared.path,
          ),
        );
      }
    }
    pendingController.clearState();
    await pendingController.deleteFiles(deleteImmediately);
    if (!context.mounted) return started;
    _toast(
      context,
      started.isEmpty
          ? 'Could not send shared files.'
          : 'Sending to ${peers.length} device${peers.length == 1 ? '' : 's'}…',
    );
    return started;
  }

  /// Audit #5 + Phase 4 (retry): wait until EVERY id in [ids] reaches a drain
  /// signal (completed OR cancelled — deliberately NOT failed, so a failed
  /// share send keeps its cache file for retry), then delete the cached share
  /// file. For a single-peer send [ids] is one id. Best-effort: a stream error
  /// still deletes so we don't leak the cache.
  Future<void> _deleteWhenDrained(
    TransferService transferService,
    PendingSharesController pendingController,
    Set<String> ids,
    String path,
  ) async {
    final remaining = {...ids};
    try {
      await for (final transfers in transferService.watchAll()) {
        for (final t in transfers) {
          if (remaining.contains(t.id) &&
              (t.status == TransferStatus.completed ||
                  t.status == TransferStatus.cancelled)) {
            remaining.remove(t.id);
          }
        }
        if (remaining.isEmpty) break;
      }
    } catch (_) {
      // A stream error means the uploads are no longer running against the
      // file — fall through to delete.
    }
    await pendingController.deleteFiles([path]);
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
