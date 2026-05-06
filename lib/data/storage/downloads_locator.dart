import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves where received files are saved + (slice 5.3.1) hands the
/// finished file off to the user-visible Downloads folder on Android.
///
/// Two-phase shape so we can stream uploads to disk on Android *without*
/// MediaStore in the hot path: stage to a private directory, then
/// [publish] copies into the public Downloads folder via the platform
/// channel once the transfer finishes. On Windows / macOS / Linux the
/// staging directory IS the Downloads folder, and [publish] is a no-op
/// returning the same path.
abstract class DownloadsLocator {
  /// Returns a writable directory; creates it if it does not exist. On
  /// Android this is a private staging area under `cacheDir`; on other
  /// platforms it's the user-facing Downloads folder.
  Future<Directory> directory();

  /// Slice 5.3.1: move a finished file from the staging directory into
  /// the user-visible Downloads folder. Returns the absolute on-disk
  /// path of the published file. The temp file at [tempFile] is
  /// deleted on success.
  ///
  /// On non-Android platforms this is a no-op that returns
  /// `tempFile.path` (the staging directory IS the Downloads folder).
  Future<String> publish({
    required File tempFile,
    required String displayName,
    String? mimeType,
  });
}

class PlatformDownloadsLocator implements DownloadsLocator {
  static const _logName = 'sharer.downloads';
  static const _channel = MethodChannel('sharer.downloads/methods');

  Directory? _cached;

  @override
  Future<Directory> directory() async {
    final cached = _cached;
    if (cached != null) return cached;

    Directory base;
    if (Platform.isAndroid) {
      // Slice 5.3.1: stage under cacheDir on Android. The decrypted
      // bytes land here while the upload is in flight; once the
      // /upload handler finishes we hand off to MediaStore via
      // [publish]. Staging in cacheDir means a crashed/aborted
      // transfer leaves no trace in the user-visible Downloads list.
      final cacheBase = await getTemporaryDirectory();
      base = Directory(
        '${cacheBase.path}${Platform.pathSeparator}sharer-staging',
      );
    } else {
      Directory? resolved;
      try {
        resolved = await getDownloadsDirectory();
      } catch (_) {
        // path_provider throws on platforms without a downloads concept
        // (notably iOS). Fall through to documents.
      }
      resolved ??= await getApplicationDocumentsDirectory();
      base = Directory('${resolved.path}${Platform.pathSeparator}Sharer');
    }

    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    _cached = base;
    return base;
  }

  @override
  Future<String> publish({
    required File tempFile,
    required String displayName,
    String? mimeType,
  }) async {
    if (!Platform.isAndroid) {
      // Other platforms staged directly into the user-visible
      // Downloads folder, so there's nothing to move.
      return tempFile.path;
    }
    try {
      final result = await _channel.invokeMethod<String>(
        'publishToDownloads',
        {
          'tempPath': tempFile.path,
          'displayName': displayName,
          'mimeType': ?mimeType,
        },
      );
      if (result == null || result.isEmpty) {
        _log('publish returned empty path; falling back to staging path');
        return tempFile.path;
      }
      _log('published ${tempFile.path} → $result');
      return result;
    } catch (e, st) {
      developer.log('publish failed', error: e, stackTrace: st, name: _logName);
      _log('publish FAILED for ${tempFile.path}: $e (file kept in staging)');
      // Returning the staging path keeps the rest of the pipeline
      // (notification, transfer-completed event) functional even when
      // MediaStore rejects us. The user can still open the file from
      // the Downloads notification action.
      return tempFile.path;
    }
  }

  void _log(String message) {
    developer.log(message, name: _logName);
    debugPrint('[$_logName] $message');
  }
}
