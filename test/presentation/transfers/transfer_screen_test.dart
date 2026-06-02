import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/transfers/transfer_screen.dart';

/// Controllable fake so the test can drive a transfer through its states.
class _FakeTransferService implements TransferService {
  final _controller = StreamController<List<Transfer>>.broadcast();
  List<Transfer> _last = const [];

  void emit(List<Transfer> transfers) {
    _last = transfers;
    _controller.add(transfers);
  }

  @override
  Stream<List<Transfer>> watchAll() async* {
    yield _last;
    yield* _controller.stream;
  }

  final cancelled = <String>[];

  @override
  Future<Transfer> send({required Peer peer, required FilePayload file}) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String transferId) async => cancelled.add(transferId);

  Future<void> dispose() => _controller.close();
}

Transfer _t(
  String id,
  TransferStatus status, {
  int sent = 0,
  int total = 100,
}) =>
    Transfer(
      id: id,
      peerId: 'p',
      peerName: 'Realme',
      fileName: 'photo.jpg',
      totalBytes: total,
      bytesTransferred: sent,
      direction: TransferDirection.sending,
      status: status,
      startedAt: DateTime.utc(2026, 6, 2),
    );

Widget _harness(_FakeTransferService svc) => ProviderScope(
      overrides: [transferServiceProvider.overrideWithValue(svc)],
      child: const MaterialApp(
        home: TransferScreen(transferIds: {'t1'}, peerName: 'Realme'),
      ),
    );

void main() {
  testWidgets('shows file name, peer, and a progress bar while in progress',
      (tester) async {
    final svc = _FakeTransferService();
    addTearDown(svc.dispose);
    svc.emit([_t('t1', TransferStatus.inProgress, sent: 40)]);

    await tester.pumpWidget(_harness(svc));
    await tester.pump();

    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('to Realme'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('plays the success check and drops the progress bar on complete',
      (tester) async {
    final svc = _FakeTransferService();
    addTearDown(svc.dispose);
    svc.emit([_t('t1', TransferStatus.inProgress, sent: 40)]);

    await tester.pumpWidget(_harness(svc));
    await tester.pump();

    svc.emit([_t('t1', TransferStatus.completed, sent: 100)]);
    await tester.pump();
    // Let the 200ms AnimatedSwitcher settle.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('Cancel button calls cancel(id) for an in-flight transfer',
      (tester) async {
    final svc = _FakeTransferService();
    addTearDown(svc.dispose);
    svc.emit([_t('t1', TransferStatus.inProgress, sent: 40)]);

    await tester.pumpWidget(_harness(svc));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();

    expect(svc.cancelled, ['t1']);
  });

  testWidgets('shows a spinner until the scoped transfer appears',
      (tester) async {
    final svc = _FakeTransferService();
    addTearDown(svc.dispose);
    // No transfer with id 't1' in the stream.
    svc.emit([_t('other', TransferStatus.inProgress)]);

    await tester.pumpWidget(_harness(svc));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('photo.jpg'), findsNothing);
  });
}
