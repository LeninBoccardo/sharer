import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/data/security/forget_service.dart';
import 'package:sharer/data/security/pair_invite_client.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/repositories/device_identity_repository.dart';
import 'package:sharer/domain/repositories/paired_devices_repository.dart';
import 'package:sharer/domain/repositories/peer_cache_repository.dart';
import 'package:sharer/presentation/pairing/devices_screen.dart';

// Trivial stubs for ForgetService's ctor deps — the overridden forgetPeer
// never touches them, so noSuchMethod is enough.
class _StubPaired implements PairedDevicesRepository {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _StubCache implements PeerCacheRepository {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _StubIdentity implements DeviceIdentityRepository {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _StubClient implements PairInviteClient {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _ThrowingForgetService extends ForgetService {
  _ThrowingForgetService()
      : super(
          pairedRepo: _StubPaired(),
          peerCache: _StubCache(),
          client: _StubClient(),
          identityRepo: _StubIdentity(),
        );
  @override
  Future<void> forgetPeer(PairedDevice p) async =>
      throw StateError('storage write failed');
}

class _OkForgetService extends ForgetService {
  _OkForgetService()
      : super(
          pairedRepo: _StubPaired(),
          peerCache: _StubCache(),
          client: _StubClient(),
          identityRepo: _StubIdentity(),
        );
  @override
  Future<void> forgetPeer(PairedDevice p) async {}
}

PairedDevice _device({String id = 'realme', String name = 'Realme'}) =>
    PairedDevice(
      deviceId: id,
      displayName: name,
      psk: Uint8List(32),
      publicKey: Uint8List(32),
      pairedAt: DateTime(2026, 5, 5),
    );

void main() {
  Widget app(ForgetService forget) => ProviderScope(
        overrides: [
          pairedDevicesStreamProvider
              .overrideWith((ref) => Stream.value([_device()])),
          forgetServiceProvider.overrideWithValue(forget),
        ],
        child: const MaterialApp(home: DevicesScreen()),
      );

  testWidgets('shows an error snackbar when forgetPeer throws (audit #19)',
      (tester) async {
    await tester.pumpWidget(app(_ThrowingForgetService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget device'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't forget Realme — try again"), findsOneWidget);
    expect(find.text('Forgot Realme'), findsNothing);
    expect(tester.takeException(), isNull,
        reason: 'the throw must be caught, not escape as an async error');
  });

  testWidgets('shows the success snackbar when forgetPeer succeeds (audit #19)',
      (tester) async {
    await tester.pumpWidget(app(_OkForgetService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget device'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot Realme'), findsOneWidget);
    expect(find.textContaining("Couldn't forget"), findsNothing);
  });
}
