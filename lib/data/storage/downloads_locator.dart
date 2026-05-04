import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves the directory where received files are saved. Injectable so
/// tests use a temp dir, and so a future MediaStore-backed
/// implementation (OQ-7) can swap in without touching consumers.
abstract class DownloadsLocator {
  /// Returns a writable directory; creates it if it does not exist.
  Future<Directory> directory();
}

class PlatformDownloadsLocator implements DownloadsLocator {
  Directory? _cached;

  @override
  Future<Directory> directory() async {
    final cached = _cached;
    if (cached != null) return cached;

    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      // path_provider throws on platforms without a downloads concept
      // (notably iOS). Fall through to documents.
    }
    base ??= await getApplicationDocumentsDirectory();

    // Keep our writes namespaced so we don't pollute the user's
    // Downloads root with a flat list of incoming files.
    final dir = Directory('${base.path}${Platform.pathSeparator}Sharer');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cached = dir;
    return dir;
  }
}
