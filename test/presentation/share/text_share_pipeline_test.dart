import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/share/incoming_share_service.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/presentation/share/pending_shares_controller.dart';

/// Dart-side proof that a text-origin share (what Kotlin extractSharedText()
/// produces: a cache .txt holding the shared text, surfaced as a normal
/// IncomingSharedFile with mimeType text/plain) threads through the existing
/// pipeline with NO special-casing. The Kotlin EXTRA_TEXT extraction itself
/// is on-device-validated (no JVM harness in this repo).
class _FakeService implements IncomingShareService {
  final _c = StreamController<List<IncomingSharedFile>>.broadcast();
  List<IncomingSharedFile>? initial;

  @override
  Stream<List<IncomingSharedFile>> get shares => _c.stream;
  @override
  Future<List<IncomingSharedFile>?> consumeInitial() async => initial;
  void emit(List<IncomingSharedFile> b) => _c.add(b);
  @override
  void start() {}
  @override
  Future<void> dispose() async => _c.close();
}

IncomingSharedFile _textShare(Directory dir, String name, String text) {
  final path = '${dir.path}${Platform.pathSeparator}share_$name';
  File(path).writeAsStringSync(text);
  return IncomingSharedFile(
    path: path,
    name: name,
    size: File(path).lengthSync(),
    mimeType: 'text/plain',
  );
}

void main() {
  late Directory tmp;
  late _FakeService svc;
  late PendingSharesController ctrl;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sharer_text_');
    svc = _FakeService();
    ctrl = PendingSharesController(svc);
  });

  tearDown(() async {
    await ctrl.dispose();
    await svc.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a shared URL arrives as a pending text/plain .txt', () async {
    svc.initial = [_textShare(tmp, 'example.com.txt', 'https://example.com/a')];
    await ctrl.start();
    final f = ctrl.state.files.single;
    expect(f.name, 'example.com.txt');
    expect(f.mimeType, 'text/plain');
    expect(File(f.path).readAsStringSync(), 'https://example.com/a');
  });

  test('a text share becomes a sendable streamed FilePayload', () async {
    svc.initial = [_textShare(tmp, 'note.txt', 'hello world')];
    await ctrl.start();
    final shared = ctrl.state.files.single;
    final payload = FilePayload(
      fileName: shared.name,
      sizeBytes: shared.size,
      bytes: File(shared.path).openRead(),
      mimeType: shared.mimeType,
    );
    expect(payload.fileName, 'note.txt');
    expect(payload.sizeBytes, greaterThan(0));
    final bytes = await payload.bytes.expand((c) => c).toList();
    expect(String.fromCharCodes(bytes), 'hello world');
  });

  test('a text share appends alongside subsequent file shares', () async {
    svc.initial = [_textShare(tmp, 'link.txt', 'https://x.test')];
    await ctrl.start();

    final p2 = '${tmp.path}${Platform.pathSeparator}share_b.bin';
    File(p2).writeAsBytesSync([1, 2, 3]);
    svc.emit([IncomingSharedFile(path: p2, name: 'b.bin', size: 3)]);
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.state.files.map((f) => f.name), ['link.txt', 'b.bin']);
  });
}
