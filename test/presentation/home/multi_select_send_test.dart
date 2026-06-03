import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/data/share/incoming_share_service.dart';
import 'package:sharer/domain/entities/paired_device.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/presentation/share/pending_shares_controller.dart';
import 'package:sharer/presentation/transfers/transfer_screen.dart';

import '../../fakes/fake_mdns_backend.dart';
import '../../fakes/fake_network_source.dart';
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

/// Pumps the home screen with two paired peers (Alpha=a, Beta=b) and one
/// nearby peer (Gamma=c). A single pending share is injected so the send
/// path takes the in-memory fan-out branch (no FilePicker MethodChannel),
/// and [recorder] captures which peers each send is dispatched to.
Future<IncomingSharedFile> _pump(
  WidgetTester tester,
  RecordingTransferService recorder,
) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  // A real temp file so the fan-out's File(path).exists() gate passes.
  final tmp = File(
    '${Directory.systemTemp.createTempSync('sharer_share').path}/group.txt',
  )..writeAsStringSync('hello');
  addTearDown(() {
    if (tmp.existsSync()) tmp.deleteSync();
  });
  final shared = IncomingSharedFile(
    path: tmp.path,
    name: 'group.txt',
    size: 5,
    mimeType: 'text/plain',
  );

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
        networkSourceProvider
            .overrideWith((ref) => FakeNetworkSource(initial: null)),
        transferServiceProvider.overrideWithValue(recorder),
        peersStreamProvider.overrideWith(
          (ref) => Stream.value(
            [_peer('a', 'Alpha'), _peer('b', 'Beta'), _peer('c', 'Gamma')],
          ),
        ),
        pairedDevicesStreamProvider
            .overrideWith((ref) => Stream.value([_device('a'), _device('b')])),
        pendingSharesProvider
            .overrideWith((ref) => Stream.value(PendingShares([shared]))),
      ],
      child: const SharerApp(),
    ),
  );
  await tester.pumpAndSettle();
  return shared;
}

void main() {
  testWidgets('long-press a paired tile enters selection mode', (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    expect(find.byType(Checkbox), findsNothing);
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();

    // Both paired tiles now show a checkbox; the action bar reads "Send to 1".
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('Send to 1'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('selecting and deselecting a second peer updates the count',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Send to 2'), findsOneWidget);

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Send to 1'), findsOneWidget);
    expect(find.text('Send to 2'), findsNothing);
  });

  testWidgets('deselecting the last peer auto-exits selection mode',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Send to 1'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    // Bar gone, normal AppBar title restored.
    expect(find.textContaining('Send to'), findsNothing);
    expect(find.text('Sharer'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('Send to 2 fans the pending share out to both paired peers',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send to 2'));
    // The fan-out awaits real File(path).exists() I/O before it records a
    // send, which a plain pumpAndSettle would skip past — runAsync turns the
    // real event loop so that I/O resolves first.
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    // One send per (peer, file) for BOTH paired peers.
    expect(recorder.sentPeerIds, {'a', 'b'});
    expect(recorder.sends.length, 2);
    // The scoped transfer screen is pushed and selection clears.
    expect(find.byType(TransferScreen), findsOneWidget);
    expect(find.text('Sending to 2 devices'), findsOneWidget);
  });

  testWidgets('a normal tap (no long-press) still sends to exactly one peer',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.tap(find.text('Alpha'));
    // Same real-I/O settle as the fan-out: let File(path).exists() resolve.
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(recorder.sentPeerIds, {'a'});
    expect(recorder.sends.length, 1);
    expect(find.byType(TransferScreen), findsOneWidget);
  });

  testWidgets('long-press on a Nearby (unpaired) tile does nothing',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.longPress(find.text('Gamma'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('Send to'), findsNothing);
  });

  testWidgets('the close action exits selection mode without sending',
      (tester) async {
    final recorder = RecordingTransferService();
    addTearDown(recorder.dispose);
    await _pump(tester, recorder);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();

    expect(find.text('Sharer'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(recorder.sends, isEmpty);
  });
}
