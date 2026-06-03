import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/transfers/transfer_detail_sheet.dart';

class _FakeTransferService implements TransferService {
  final retried = <String>[];
  @override
  Stream<List<Transfer>> watchAll() => const Stream.empty();
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
  Future<void> retry(String transferId) async => retried.add(transferId);
}

Transfer _failed({
  String? error,
  bool canRetry = false,
  TransferDirection direction = TransferDirection.sending,
}) =>
    Transfer(
      id: 't1',
      peerId: 'p',
      peerName: 'Realme',
      fileName: 'photo.jpg',
      totalBytes: 4096,
      direction: direction,
      status: TransferStatus.failed,
      startedAt: DateTime.utc(2026, 6, 2, 10),
      completedAt: DateTime.utc(2026, 6, 2, 10, 1),
      errorMessage: error,
      canRetry: canRetry,
    );

Future<void> _open(WidgetTester tester, _FakeTransferService svc, Transfer t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transferServiceProvider.overrideWithValue(svc)],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => ElevatedButton(
            onPressed: () => showTransferDetailSheet(context, ref, t),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows mapped headline + metadata + raw error in Technical details',
      (tester) async {
    final svc = _FakeTransferService();
    await _open(
      tester,
      svc,
      _failed(error: 'Upload failed: 403  reason=unknown-sender (POST x)'),
    );

    expect(find.text('This device removed you'), findsOneWidget);
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('Realme'), findsOneWidget);

    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('reason=unknown-sender'), findsOneWidget);
  });

  testWidgets('Retry records retry(id) and pops the sheet', (tester) async {
    final svc = _FakeTransferService();
    await _open(
      tester,
      svc,
      _failed(error: 'SocketException: Connection refused', canRetry: true),
    );

    expect(find.text('Peer not reachable'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(svc.retried, ['t1']);
    expect(find.text('Peer not reachable'), findsNothing); // sheet popped
  });

  testWidgets('incoming failure shows no Retry and no send-only hint',
      (tester) async {
    final svc = _FakeTransferService();
    await _open(
      tester,
      svc,
      _failed(error: 'boom', direction: TransferDirection.receiving),
    );

    expect(find.widgetWithText(FilledButton, 'Retry'), findsNothing);
    expect(find.textContaining('Source no longer available'), findsNothing);
  });
}
