import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';
import 'package:sharer/presentation/transfers/transfers_section.dart';

/// Controllable fake whose [watchAll] stream we can drive with an
/// arbitrary sequence of snapshots so we can exercise list churn.
class _ControllableTransferService implements TransferService {
  final _controller = StreamController<List<Transfer>>.broadcast();

  void emit(List<Transfer> list) => _controller.add(list);
  Future<void> close() => _controller.close();

  @override
  Stream<List<Transfer>> watchAll() => _controller.stream;

  @override
  Future<Transfer> send({required Peer peer, required FilePayload file}) {
    throw UnimplementedError('send() not used by this test');
  }

  @override
  Future<void> cancel(String transferId) async {}
}

Transfer _received(String id) => Transfer(
      id: id,
      peerId: 'peer-1',
      peerName: 'Peer One',
      fileName: 'photo.jpg',
      totalBytes: 1000,
      bytesTransferred: 1000,
      direction: TransferDirection.receiving,
      status: TransferStatus.completed,
      startedAt: DateTime.utc(2026, 5, 4),
    );

void main() {
  testWidgets(
      'announced-set is pruned when a transfer ages out, so a reused id '
      're-announces (set does not grow unbounded) (audit #42)',
      (tester) async {
    final service = _ControllableTransferService();
    addTearDown(service.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transferServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: TransfersSection(),
          ),
        ),
      ),
    );

    // First appearance of r1: announced exactly once.
    service.emit([_received('r1')]);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Received'), findsOneWidget);

    // r1 ages out of the list -> retainAll prunes it from the set.
    service.emit(const <Transfer>[]);
    await tester.pump();
    // Dismiss the lingering snackbar so the next assertion is unambiguous.
    ScaffoldMessenger.of(tester.element(find.byType(TransfersSection)))
        .clearSnackBars();
    await tester.pump(); // begin the dismiss animation
    await tester.pump(const Duration(milliseconds: 500)); // let it complete
    expect(find.byType(SnackBar), findsNothing);

    // r1 re-enters as completed. Because it was pruned, it announces
    // again. Under the unpruned (buggy) code r1 would still be in the
    // set and this snackbar would never show.
    service.emit([_received('r1')]);
    await tester.pump(); // stream delivers -> showSnackBar enqueued
    await tester.pump(const Duration(milliseconds: 750)); // snackbar animates in
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Received'), findsOneWidget);
  });
}
