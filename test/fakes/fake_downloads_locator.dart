import 'dart:io';

import 'package:sharer/data/storage/downloads_locator.dart';

class FakeDownloadsLocator implements DownloadsLocator {
  final Directory dir;
  FakeDownloadsLocator(this.dir);

  @override
  Future<Directory> directory() async => dir;
}
