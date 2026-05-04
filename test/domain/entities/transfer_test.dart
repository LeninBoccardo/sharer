import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/domain/entities/transfer.dart';

Transfer _make({
  int total = 1000,
  int sent = 0,
  TransferStatus status = TransferStatus.inProgress,
}) {
  return Transfer(
    id: 'id',
    peerId: 'peer',
    peerName: 'Peer',
    fileName: 'foo.txt',
    totalBytes: total,
    bytesTransferred: sent,
    direction: TransferDirection.sending,
    status: status,
    startedAt: DateTime.utc(2026, 5, 4),
  );
}

void main() {
  group('Transfer', () {
    test('progress is bytesTransferred / totalBytes', () {
      expect(_make(total: 1000, sent: 250).progress, 0.25);
      expect(_make(total: 1000, sent: 1000).progress, 1.0);
    });

    test('progress is 0 when totalBytes is 0', () {
      expect(_make(total: 0, sent: 100).progress, 0);
    });

    test('progress is clamped to [0,1]', () {
      expect(_make(total: 1000, sent: 1500).progress, 1.0);
      expect(_make(total: 1000, sent: -50).progress, 0.0);
    });

    test('isTerminal covers completed, failed, cancelled only', () {
      expect(_make(status: TransferStatus.pending).isTerminal, isFalse);
      expect(_make(status: TransferStatus.inProgress).isTerminal, isFalse);
      expect(_make(status: TransferStatus.completed).isTerminal, isTrue);
      expect(_make(status: TransferStatus.failed).isTerminal, isTrue);
      expect(_make(status: TransferStatus.cancelled).isTerminal, isTrue);
    });

    test('copyWith preserves identity fields and overrides others', () {
      final base = _make(total: 1000, sent: 100);
      final next = base.copyWith(
        bytesTransferred: 500,
        status: TransferStatus.completed,
      );
      expect(next.id, base.id);
      expect(next.fileName, base.fileName);
      expect(next.bytesTransferred, 500);
      expect(next.status, TransferStatus.completed);
    });
  });
}
