import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/presentation/transfers/transfer_rate_line.dart';

Transfer _t(int sent, {int total = 1000}) => Transfer(
      id: 't1',
      peerId: 'p',
      peerName: 'Realme',
      fileName: 'f.bin',
      totalBytes: total,
      bytesTransferred: sent,
      direction: TransferDirection.sending,
      status: TransferStatus.inProgress,
      startedAt: DateTime.utc(2026, 6, 2),
    );

/// Pumps a TransferRateLine and feeds it two increasing-byte samples so it
/// has a positive time delta (real wall clock between builds) and renders a
/// rate. Returns once the second sample has been recorded.
Future<void> _drive(WidgetTester tester, {required int total}) async {
  var sent = 200;
  late StateSetter setOuter;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return TransferRateLine(transfer: _t(sent, total: total));
        },
      ),
    ),
  ));
  await tester.pump();
  setOuter(() => sent = 600);
  await tester.pump();
}

bool _isRateText(Widget w) =>
    w is Text && RegExp(r'(B|KB|MB|GB)/s').hasMatch(w.data ?? '');

void main() {
  testWidgets('renders a throughput + ETA line once it has two samples',
      (tester) async {
    await _drive(tester, total: 1000);
    expect(find.byWidgetPredicate(_isRateText), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);
  });

  testWidgets('shows a rate but no ETA when the total is unknown',
      (tester) async {
    await _drive(tester, total: 0);
    expect(find.byWidgetPredicate(_isRateText), findsOneWidget);
    expect(find.textContaining('left'), findsNothing);
  });

  testWidgets('renders nothing on the very first frame (one sample)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TransferRateLine(transfer: _t(200))),
    ));
    await tester.pump();
    expect(find.byWidgetPredicate(_isRateText), findsNothing);
  });
}
