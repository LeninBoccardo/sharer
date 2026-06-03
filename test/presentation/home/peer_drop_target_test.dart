import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/home/dropped_file_sender.dart';
import 'package:sharer/presentation/transfers/transfer_screen.dart';

import '../../fakes/fake_mdns_backend.dart';
import '../../fakes/fake_network_source.dart';
import '../../fakes/fake_transfer_service.dart';
import '../../fakes/recording_transfer_service.dart';

Peer _peer(String id, String name) => Peer(
      id: id,
      name: name,
      host: '10.0.0.5',
      port: 8080,
      lastSeen: DateTime.utc(2026, 6, 2),
    );

PairedDevice _device(String id) => PairedDevice(
      deviceId: id,
      displayName: id,
      psk: Uint8List(32),
      publicKey: Uint8List(32),
      pairedAt: DateTime.utc(2026, 6, 2),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<Peer> peers,
  required List<PairedDevice> paired,
  TransferService? transfers,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
        networkSourceProvider
            .overrideWith((ref) => FakeNetworkSource(initial: null)),
        transferServiceProvider
            .overrideWithValue(transfers ?? FakeTransferService(const [])),
        peersStreamProvider.overrideWith((ref) => Stream.value(peers)),
        pairedDevicesStreamProvider.overrideWith((ref) => Stream.value(paired)),
      ],
      child: const SharerApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Platform reports the HOST OS in flutter test, so force the desktop branch
  // on regardless of which OS CI runs on. Reset after each test.
  setUp(() => debugDesktopDropSupportedOverride = true);
  tearDown(() => debugDesktopDropSupportedOverride = null);

  testWidgets('a paired + reachable tile is wrapped in a DropTarget',
      (tester) async {
    await _pump(
      tester,
      peers: [_peer('a', 'Alpha')],
      paired: [_device('a')],
    );
    expect(find.byType(DropTarget), findsOneWidget);
  });

  testWidgets('an unpaired tile is NOT a drop target', (tester) async {
    await _pump(
      tester,
      peers: [_peer('b', 'Beta')],
      paired: const [],
    );
    expect(find.byType(DropTarget), findsNothing);
  });

  testWidgets('no DropTarget when the platform does not support it',
      (tester) async {
    debugDesktopDropSupportedOverride = false;
    await _pump(
      tester,
      peers: [_peer('a', 'Alpha')],
      paired: [_device('a')],
    );
    expect(find.byType(DropTarget), findsNothing);
  });

  testWidgets('dropping a file sends it to the peer and opens the transfer '
      'screen', (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(
      tester,
      peers: [_peer('a', 'Alpha')],
      paired: [_device('a')],
      transfers: recorder,
    );

    final tmp = File(
      '${Directory.systemTemp.createTempSync('sharer_drop_w').path}/d.txt',
    )..writeAsStringSync('hi');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync();
    });

    final dropTarget = tester.widget<DropTarget>(find.byType(DropTarget));
    final details = DropDoneDetails(
      files: [DropItemFile(tmp.path, name: 'd.txt', length: 2)],
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    );
    // Fire the drop callback; runAsync lets the real File I/O in the send path
    // resolve (a plain pumpAndSettle would skip past it).
    await tester.runAsync(() async {
      dropTarget.onDragDone!(details);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(recorder.sentPeerIds, {'a'});
    expect(find.byType(TransferScreen), findsOneWidget);
  });
}
