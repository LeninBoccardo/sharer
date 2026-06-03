import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mime/mime.dart';

import '../../domain/entities/file_payload.dart';
import '../../domain/entities/peer.dart';
import '../../domain/repositories/transfer_service.dart';

/// Minimal value shape for one dropped file, decoupled from cross_file's
/// `XFile` so the send logic stays pure-Dart and unit-testable without a
/// real OS drop or any platform channel.
class DroppedFileSpec {
  const DroppedFileSpec({
    required this.path,
    required this.name,
    required this.size,
  });

  /// Absolute OS path the drop handed us.
  final String path;

  /// Basename used as the wire filename.
  final String name;

  /// Size in bytes (from `XFile.length()`).
  final int size;
}

/// Outcome of a [sendDroppedFiles] fan-out over a single peer.
class DropSendResult {
  const DropSendResult({
    required this.started,
    required this.queued,
    required this.skipped,
  });

  /// Ids of the transfers that actually started.
  final Set<String> started;
  final int queued;
  final int skipped;
}

/// Streams a [FilePayload] per existing-on-disk [files] spec and calls
/// [service].send for [peer], mirroring the picker/pending send paths.
///
/// Never buffers a file: `bytes` is `File(path).openRead()` and the retained
/// `reopen` factory re-opens from zero so a failed send can retry. Per-file
/// failures (missing path, send throwing) are counted in [DropSendResult.skipped]
/// and never abort the batch. Pure: no BuildContext, no ref, no Flutter widget.
Future<DropSendResult> sendDroppedFiles({
  required TransferService service,
  required Peer peer,
  required List<DroppedFileSpec> files,
}) async {
  final started = <String>{};
  var queued = 0;
  var skipped = 0;
  for (final spec in files) {
    try {
      final file = File(spec.path);
      if (!await file.exists()) {
        skipped++;
        continue;
      }
      final transfer = await service.send(
        peer: peer,
        file: FilePayload(
          fileName: spec.name,
          sizeBytes: spec.size,
          bytes: file.openRead(),
          mimeType: lookupMimeType(spec.name),
        ),
        reopen: () => File(spec.path).openRead(),
      );
      started.add(transfer.id);
      queued++;
    } catch (_) {
      // A bad path / mid-send failure surfaces on that transfer's card (or
      // is simply skipped if send never started). One file never aborts the
      // batch.
      skipped++;
    }
  }
  return DropSendResult(started: started, queued: queued, skipped: skipped);
}

/// Test-only override for [isDesktopDropSupported]. `null` = use the real
/// platform check. Tests set this to force-enable the drop UX on a non-desktop
/// CI host (in `flutter test`, `Platform` reports the host OS); reset to `null`
/// in a tearDown.
bool? debugDesktopDropSupportedOverride;

/// Whether the running platform supports the desktop drag-and-drop send UX.
/// Centralised so the tile and tests share one definition. The DropTarget is
/// only ever built when this is true, so mobile/web tiles never reference
/// desktop_drop.
bool get isDesktopDropSupported =>
    debugDesktopDropSupportedOverride ??
    (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS));
