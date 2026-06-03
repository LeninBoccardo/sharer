import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/presentation/transfers/transfers_section.dart';

import '../../fakes/fake_transfer_service.dart';

Transfer _t(TransferStatus s, TransferDirection d) => Transfer(
      id: 's',
      peerId: 'p',
      peerName: 'Realme',
      fileName: 'photo.jpg',
      totalBytes: 1000,
      bytesTransferred: s == TransferStatus.completed ? 1000 : 400,
      direction: d,
      status: s,
      startedAt: DateTime.utc(2026, 5, 4),
    );

Future<void> _pump(WidgetTester tester, Transfer t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      transferServiceProvider.overrideWithValue(FakeTransferService([t])),
    ],
    child: const MaterialApp(home: Scaffold(body: TransfersSection())),
  ));
  await tester.pump();
}

void main() {
  testWidgets('every status renders a visible text label (not color-only)',
      (tester) async {
    const cases = {
      TransferStatus.pending: 'Queued',
      TransferStatus.inProgress: 'Sending',
      TransferStatus.completed: 'Done',
      TransferStatus.failed: 'Failed',
      TransferStatus.cancelled: 'Cancelled',
    };
    for (final e in cases.entries) {
      await _pump(tester, _t(e.key, TransferDirection.sending));
      expect(find.text(e.value), findsOneWidget,
          reason: 'missing visible label for ${e.key}');
    }
  });

  testWidgets('the direction icon carries a Sending semantics label',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _t(TransferStatus.inProgress, TransferDirection.sending));
    expect(find.bySemanticsLabel(RegExp('Sending')), findsWidgets);
    handle.dispose();
  });
}
