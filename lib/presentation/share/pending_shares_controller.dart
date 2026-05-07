import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../data/share/incoming_share_service.dart';

/// State held by [PendingSharesController]. Empty when no share is
/// waiting to be routed to a peer; non-empty when the user shared one
/// or more files into Sharer and the home screen should surface a
/// "pick a destination" affordance.
class PendingShares {
  const PendingShares(this.files);
  final List<IncomingSharedFile> files;

  bool get isEmpty => files.isEmpty;
  bool get isNotEmpty => files.isNotEmpty;

  static const empty = PendingShares([]);
}

/// Slice 5.5: in-memory FIFO of files the OS share-sheet handed to us.
///
/// The home screen watches this controller; when it has files, the
/// peer tile's tap behavior changes from "open file picker" to "send
/// these files to this peer". Once sent (or dismissed), the queue
/// clears and tap reverts to the picker flow.
///
/// Bound to [IncomingShareService]'s cold-start + event streams in
/// [start]. Disposed alongside the provider.
class PendingSharesController {
  PendingSharesController(this._service);

  final IncomingShareService _service;
  final _stateController = StreamController<PendingShares>.broadcast();
  StreamSubscription<List<IncomingSharedFile>>? _sub;

  PendingShares _state = PendingShares.empty;
  PendingShares get state => _state;
  Stream<PendingShares> get stream => _stateController.stream;

  Future<void> start() async {
    final initial = await _service.consumeInitial();
    if (initial != null && initial.isNotEmpty) {
      _emit(PendingShares(List.unmodifiable(initial)));
    }
    _sub = _service.shares.listen((batch) {
      if (batch.isEmpty) return;
      // Append to whatever's already pending so a second share before
      // the user picks a peer doesn't drop the first.
      _emit(PendingShares(
        List.unmodifiable([..._state.files, ...batch]),
      ));
    });
    // Slice 5.x.3.6: best-effort sweep of cacheDir/share_* files older
    // than 24h. clear() only deletes paths in current state, so a
    // share that was consumed via consumeInitial then dropped before
    // the user picked a peer (app backgrounded, killed, etc.) leaks.
    // The OS reclaims under pressure but a 4 GB shared video can sit
    // for weeks. Don't await — fire and forget so startup isn't
    // blocked by stat calls.
    if (Platform.isAndroid) {
      unawaited(_sweepStaleShareCache());
    }
  }

  Future<void> _sweepStaleShareCache() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('share_')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {/* one bad file shouldn't abort the sweep */}
      }
    } catch (_) {/* never fail startup for opportunistic cleanup */}
  }

  /// Called after the home screen has handed the files off to a
  /// transfer (or the user dismissed the banner). Best-effort cleanup
  /// of the cached files we copied onto disk.
  Future<void> clear() async {
    final toDelete = _state.files;
    _emit(PendingShares.empty);
    for (final f in toDelete) {
      try {
        final file = File(f.path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Cache files; the OS will reap them eventually.
      }
    }
  }

  void _emit(PendingShares next) {
    _state = next;
    _stateController.add(next);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _stateController.close();
  }
}
