import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/data/security/hmac_verifier.dart';
import 'package:sharer/data/security/paired_devices_store.dart';
import 'package:sharer/data/transport/http_file_server.dart';
import 'package:sharer/presentation/pairing/show_pair_screen.dart';

import '../../fakes/fake_brightness_controller.dart';
import '../../fakes/fake_downloads_locator.dart';
import '../../fakes/fake_secure_key_value_store.dart';

// Mounts ShowPairScreen on its fast ERROR path (an unstarted HttpFileServer
// reports a null boundPort, so _bootstrap bails before any TLS/offer work) —
// enough to exercise the brightness lifecycle without a real socket/keygen.
void main() {
  testWidgets(
      'boosts brightness on show, restores on pause, re-boosts on resume, '
      'and the LAST call after dispose is restore (never left bright)',
      (tester) async {
    final fake = FakeBrightnessController();
    final tmp = Directory.systemTemp.createTempSync('sp_bright_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final server = HttpFileServer(
      downloads: FakeDownloadsLocator(tmp),
      isTrusted: const Stream<bool>.empty(),
      verifier: HmacVerifier(
        PairedDevicesStore(FakeSecureKeyValueStore()),
        localDeviceId: Future.value('me'),
      ),
      port: 0,
    ); // NOT started -> boundPort stays null -> error path.
    addTearDown(server.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        brightnessControllerProvider.overrideWithValue(fake),
        httpFileServerProvider.overrideWithValue(server),
      ],
      child: const MaterialApp(home: ShowPairScreen()),
    ));
    await tester.pumpAndSettle();

    expect(fake.boostCount, greaterThanOrEqualTo(1),
        reason: 'boosted as soon as the screen showed');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(fake.calls, contains('restore'),
        reason: 'restored when backgrounded');

    final beforeResume = fake.boostCount;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(fake.boostCount, greaterThan(beforeResume),
        reason: 're-boosted on resume');

    // Dispose the screen by replacing the tree.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(fake.calls.last, 'restore',
        reason: 'the device is never left pinned bright after leaving the QR');
  });
}
