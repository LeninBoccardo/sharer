import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/transfers/received_file_actions.dart';
import 'package:sharer/presentation/transfers/transfers_section.dart';

class _Fake implements TransferService {
  _Fake(this._list);
  final List<Transfer> _list;
  @override
  Stream<List<Transfer>> watchAll() => Stream.value(_list);
  @override
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> cancel(String transferId) async {}
  @override
  Future<void> retry(String transferId) async {}
}

class _Recorder {
  final opened = <String>[];
  final revealed = <String>[];
  final shared = <String>[];

  ReceivedFileActions get actions => ReceivedFileActions(
        open: (p) async => opened.add(p),
        reveal: (p) async => revealed.add(p),
        shareOnward: (p, {origin}) async => shared.add(p),
      );
}

Transfer _recv({
  String? savedPath,
  TransferStatus status = TransferStatus.completed,
  TransferDirection direction = TransferDirection.receiving,
}) =>
    Transfer(
      id: 'r1',
      peerId: 'p',
      peerName: 'Realme',
      fileName: 'photo.jpg',
      totalBytes: 1000,
      bytesTransferred: 1000,
      direction: direction,
      status: status,
      startedAt: DateTime.utc(2026, 6, 2),
      savedPath: savedPath,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<Transfer> transfers,
  required _Recorder rec,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      transferServiceProvider.overrideWithValue(_Fake(transfers)),
      receivedFileActionsProvider.overrideWithValue(rec.actions),
    ],
    child: const MaterialApp(home: Scaffold(body: TransfersSection())),
  ));
  await tester.pump();
}

void main() {
  const path = '/downloads/photo.jpg';

  testWidgets('Open + Share render and pass the exact savedPath',
      (tester) async {
    final rec = _Recorder();
    await _pump(tester, transfers: [_recv(savedPath: path)], rec: rec);

    expect(find.widgetWithText(TextButton, 'Open'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Share'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Open'));
    await tester.tap(find.widgetWithText(TextButton, 'Share'));
    await tester.pump();

    expect(rec.opened, [path]);
    expect(rec.shared, [path]);
  });

  testWidgets('Reveal appears + works on desktop platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final rec = _Recorder();
      await _pump(tester, transfers: [_recv(savedPath: path)], rec: rec);

      expect(find.widgetWithText(TextButton, 'Reveal'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reveal'));
      await tester.pump();
      expect(rec.revealed, [path]);
    } finally {
      // Reset inside the body: the framework's foundation-var check runs
      // before addTearDown callbacks.
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('content:// savedPath shows Open but hides Share', (tester) async {
    final rec = _Recorder();
    await _pump(
        tester, transfers: [_recv(savedPath: 'content://media/42')], rec: rec);

    expect(find.widgetWithText(TextButton, 'Open'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Share'), findsNothing);
  });

  testWidgets('no actions for a completed receive without a savedPath',
      (tester) async {
    final rec = _Recorder();
    await _pump(tester, transfers: [_recv(savedPath: null)], rec: rec);

    expect(find.widgetWithText(TextButton, 'Open'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Share'), findsNothing);
  });

  testWidgets('no received-actions on a completed SENDING transfer',
      (tester) async {
    final rec = _Recorder();
    await _pump(
      tester,
      transfers: [
        _recv(savedPath: path, direction: TransferDirection.sending)
      ],
      rec: rec,
    );

    expect(find.widgetWithText(TextButton, 'Open'), findsNothing);
  });
}
