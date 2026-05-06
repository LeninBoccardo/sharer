import 'dart:io';

import 'package:sharer/data/storage/downloads_locator.dart';

class FakeDownloadsLocator implements DownloadsLocator {
  final Directory dir;
  FakeDownloadsLocator(this.dir);

  @override
  Future<Directory> directory() async => dir;

  /// Slice 5.3.1: tests stage and publish to the same directory, so
  /// `publish` is a no-op that returns the staging path. The
  /// production locator on Android moves to the public Downloads
  /// folder via a method channel; tests don't exercise that path.
  @override
  Future<String> publish({
    required File tempFile,
    required String displayName,
    String? mimeType,
  }) async {
    return tempFile.path;
  }
}
