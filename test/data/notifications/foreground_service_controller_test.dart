import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/notifications/foreground_service_controller.dart';
import 'package:sharer/data/notifications/foreground_service_gateway.dart';
import 'package:sharer/domain/entities/paired_device.dart';

class _FakeGateway implements ForegroundServiceGateway {
  final calls = <String>[];
  bool _running = false;

  @override
  Future<void> init() async {
    calls.add('init');
  }

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
  }) async {
    calls.add(_running ? 'update($text)' : 'start($text)');
    _running = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _running = false;
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;
}

PairedDevice _device(String id, String name) => PairedDevice(
      deviceId: id,
      displayName: name,
      psk: Uint8List(32),
      publicKey: Uint8List(32),
      pairedAt: DateTime(2026, 5, 5),
    );

void main() {
  group('ForegroundServiceController', () {
    late _FakeGateway gateway;
    late StreamController<List<PairedDevice>> stream;
    late ForegroundServiceController controller;

    setUp(() {
      gateway = _FakeGateway();
      stream = StreamController<List<PairedDevice>>.broadcast();
      controller = ForegroundServiceController(
        pairedDevices: stream.stream,
        gateway: gateway,
      );
    });

    tearDown(() async {
      await controller.dispose();
      await stream.close();
    });

    test('init runs once on first start, never again on re-emission',
        () async {
      await controller.start();
      stream.add([]);
      await pumpEventQueue();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      stream.add([]);
      await pumpEventQueue();

      final inits = gateway.calls.where((c) => c == 'init').length;
      expect(inits, 1);
    });

    test('first emission with non-empty list starts the service', () async {
      await controller.start();
      stream.add([_device('a', 'Realme')]);
      await pumpEventQueue();
      expect(
        gateway.calls,
        ['init', 'start(Listening for files)'],
      );
    });

    test('first emission with empty list does NOT touch the service',
        () async {
      await controller.start();
      stream.add([]);
      await pumpEventQueue();
      expect(gateway.calls, ['init']);
    });

    test('empty → non-empty transition starts the service', () async {
      await controller.start();
      stream.add([]);
      await pumpEventQueue();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      expect(gateway.calls.last, startsWith('start('));
    });

    test('non-empty → empty transition stops the service', () async {
      await controller.start();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      stream.add([]);
      await pumpEventQueue();
      expect(gateway.calls.last, 'stop');
    });

    test('count change while non-empty does NOT re-update the notification '
        '(text is generic so a count change is irrelevant)', () async {
      await controller.start();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      stream.add([_device('a', 'A'), _device('b', 'B')]);
      await pumpEventQueue();
      // Only the initial start — no follow-up update.
      expect(
        gateway.calls,
        ['init', 'start(Listening for files)'],
      );
    });

    test('repeated empty emissions are idempotent', () async {
      await controller.start();
      stream.add([]);
      stream.add([]);
      stream.add([]);
      await pumpEventQueue();
      // No start, no stop, only the init.
      expect(gateway.calls, ['init']);
    });

    test('full bouncing lifecycle: empty → 1 → 2 → 0 → 1', () async {
      await controller.start();
      stream.add([]);
      await pumpEventQueue();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      stream.add([_device('a', 'A'), _device('b', 'B')]);
      await pumpEventQueue();
      stream.add([]);
      await pumpEventQueue();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      expect(gateway.calls, [
        'init',
        'start(Listening for files)',
        // No update for the count change while running.
        'stop',
        'start(Listening for files)',
      ]);
    });

    test('dispose cancels the subscription', () async {
      await controller.start();
      await controller.dispose();
      stream.add([_device('a', 'A')]);
      await pumpEventQueue();
      expect(gateway.calls, ['init'],
          reason: 'no further calls after dispose');
    });
  });
}
