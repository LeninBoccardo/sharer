import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/share/incoming_share_service.dart';
import 'package:sharer/presentation/share/pending_shares_controller.dart';

/// Stub that lets the test drive both the cold-start initial share and
/// subsequent share emissions.
class _FakeService implements IncomingShareService {
  final _controller = StreamController<List<IncomingSharedFile>>.broadcast();

  List<IncomingSharedFile>? initial;

  @override
  Stream<List<IncomingSharedFile>> get shares => _controller.stream;

  @override
  Future<List<IncomingSharedFile>?> consumeInitial() async => initial;

  void emit(List<IncomingSharedFile> batch) => _controller.add(batch);

  @override
  void start() {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

IncomingSharedFile _file(Directory dir, String name) {
  final path = '${dir.path}${Platform.pathSeparator}$name';
  File(path).writeAsStringSync('content of $name');
  return IncomingSharedFile(
    path: path,
    name: name,
    size: File(path).lengthSync(),
    mimeType: 'text/plain',
  );
}

void main() {
  late Directory tmp;
  late _FakeService service;
  late PendingSharesController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sharer_pending_test_');
    service = _FakeService();
    controller = PendingSharesController(service);
  });

  tearDown(() async {
    await controller.dispose();
    await service.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('start with no initial share leaves state empty', () async {
    await controller.start();
    expect(controller.state.isEmpty, isTrue);
  });

  test('start with an initial share immediately populates state',
      () async {
    service.initial = [_file(tmp, 'a.txt')];
    await controller.start();
    expect(controller.state.files, hasLength(1));
    expect(controller.state.files.single.name, 'a.txt');
  });

  test('subsequent share batches are appended to existing state',
      () async {
    service.initial = [_file(tmp, 'a.txt')];
    await controller.start();

    service.emit([_file(tmp, 'b.txt'), _file(tmp, 'c.txt')]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.files.map((f) => f.name),
        ['a.txt', 'b.txt', 'c.txt']);
  });

  test('clear empties state and deletes the cached files', () async {
    final f = _file(tmp, 'a.txt');
    service.initial = [f];
    await controller.start();
    expect(File(f.path).existsSync(), isTrue);

    await controller.clear();

    expect(controller.state.isEmpty, isTrue);
    expect(File(f.path).existsSync(), isFalse);
  });

  test('clearState empties state but does NOT delete the cached files '
      '(audit #5 deferred delete)', () async {
    final f = _file(tmp, 'a.txt');
    service.initial = [f];
    await controller.start();
    expect(File(f.path).existsSync(), isTrue);

    final paths = controller.clearState();

    expect(controller.state.isEmpty, isTrue);
    expect(paths, [f.path]);
    expect(File(f.path).existsSync(), isTrue,
        reason: 'clearState must leave the file for the in-flight upload');
  });

  test('deleteFiles removes the given cached files', () async {
    final f = _file(tmp, 'a.txt');
    service.initial = [f];
    await controller.start();
    final paths = controller.clearState();

    await controller.deleteFiles(paths);

    expect(File(f.path).existsSync(), isFalse);
  });

  test('deleteFiles tolerates a missing path', () async {
    await controller.deleteFiles(['${tmp.path}/does-not-exist.bin']);
    // No throw == pass.
  });

  test('emitting an empty batch is a no-op (does not bump the state)',
      () async {
    await controller.start();
    final emissions = <int>[];
    final sub = controller.stream.listen((s) => emissions.add(s.files.length));

    service.emit(const []);
    await Future<void>.delayed(Duration.zero);

    expect(emissions, isEmpty);
    await sub.cancel();
  });

  test('stream emits each state transition for late subscribers '
      '(append + clear)', () async {
    await controller.start();
    final emissions = <int>[];
    final sub = controller.stream.listen((s) => emissions.add(s.files.length));

    service.emit([_file(tmp, 'a.txt')]);
    await Future<void>.delayed(Duration.zero);
    service.emit([_file(tmp, 'b.txt')]);
    await Future<void>.delayed(Duration.zero);
    await controller.clear();

    expect(emissions, [1, 2, 0]);
    await sub.cancel();
  });
}
