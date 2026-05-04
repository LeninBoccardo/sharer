import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/domain/entities/paired_device.dart';

void main() {
  Uint8List psk(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  Uint8List pub(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (100 + seed + i) & 0xff));

  PairedDevice make({
    String deviceId = 'a',
    String displayName = 'Phone',
    int seed = 1,
    String? certFingerprint,
    DateTime? pairedAt,
  }) =>
      PairedDevice(
        deviceId: deviceId,
        displayName: displayName,
        psk: psk(seed),
        publicKey: pub(seed),
        certFingerprint: certFingerprint,
        pairedAt: pairedAt ?? DateTime.utc(2026, 5, 4, 10),
      );

  test('rejects PSK that is not exactly 32 bytes', () {
    expect(
      () => PairedDevice(
        deviceId: 'a',
        displayName: 'x',
        psk: Uint8List(16),
        publicKey: Uint8List(32),
        pairedAt: DateTime.utc(2026, 5, 4),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('rejects publicKey that is not exactly 32 bytes', () {
    expect(
      () => PairedDevice(
        deviceId: 'a',
        displayName: 'x',
        psk: Uint8List(32),
        publicKey: Uint8List(16),
        pairedAt: DateTime.utc(2026, 5, 4),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('equality compares PSK byte-by-byte, not by reference', () {
    final a = make();
    final b = make();
    expect(identical(a.psk, b.psk), isFalse);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('equality detects PSK mismatch', () {
    final a = make(seed: 1);
    final b = make(seed: 2);
    expect(a, isNot(equals(b)));
  });

  test('copyWith preserves deviceId and overrides only requested fields', () {
    final a = make(displayName: 'Phone');
    final b = a.copyWith(displayName: 'Phone (renamed)');
    expect(b.deviceId, a.deviceId);
    expect(b.displayName, 'Phone (renamed)');
    expect(b.psk, a.psk);
    expect(b.pairedAt, a.pairedAt);
  });
}
