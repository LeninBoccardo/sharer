import 'dart:async';
import 'dart:io';

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
