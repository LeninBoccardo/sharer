import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/data/transport/http_file_client.dart';
import 'package:sharer/data/transport/transport_protocol.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/transfer/transfer_error_guidance.dart';

// Construct the REAL exception objects and feed their toString() to the
// mapper, so the assertions pin the actual transport/SDK wording — an SDK
// or transport wording change then fails this test loudly.
void main() {
  const sending = TransferDirection.sending;
  const receiving = TransferDirection.receiving;

  test('403 unknown-sender -> rePair (peer removed us)', () {
    final e = UploadStatusException(
      statusCode: 403,
      body: '',
      uri: Uri.parse('https://h:8080/upload'),
      reason: TransportProtocol.reasonUnknownSender,
    );
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.action, TransferErrorAction.rePair);
    expect(g.headline, contains('removed you'));
    expect(g.raw, e.toString());
  });

  test('507 storage-full -> freeSpace', () {
    final e = UploadStatusException(
      statusCode: 507,
      body: '',
      uri: Uri.parse('https://h:8080/upload'),
      reason: TransportProtocol.reasonStorageFull,
    );
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.action, TransferErrorAction.freeSpace);
    expect(g.headline, 'Not enough space');
  });

  test('receive-side "exceeded size bound" -> freeSpace', () {
    final g = mapTransferError(
      'upload exceeded size bound: received=999 bytes, ceiling=500 bytes',
      direction: receiving,
    );
    expect(g.action, TransferErrorAction.freeSpace);
  });

  test('UnpinnedPeerException -> rePair (secure not set up)', () {
    final e = UnpinnedPeerException(host: 'h', port: 8080);
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.action, TransferErrorAction.rePair);
    expect(g.headline, contains('Secure'));
  });

  test('HandshakeException -> Peer not reachable', () {
    final e = HandshakeException('certificate verify failed');
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.headline, 'Peer not reachable');
    expect(g.action, TransferErrorAction.retryOrRePair);
  });

  test('SocketException failed host lookup -> Peer not reachable', () {
    final e = SocketException("Failed host lookup: 'realme.local'");
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.headline, 'Peer not reachable');
  });

  test('SocketException connection refused -> Peer not reachable', () {
    final e = SocketException('Connection refused',
        osError: const OSError('', 111));
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.headline, 'Peer not reachable');
  });

  test('PayloadSizeMismatchException -> retry (file changed)', () {
    final e = PayloadSizeMismatchException(
        declaredBytes: 10, actualBytes: 5, fileName: 'a.bin');
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.action, TransferErrorAction.retry);
    expect(g.headline, contains('changed'));
  });

  test('bare 401 upload failure -> declined (retryOrRePair)', () {
    final e = UploadStatusException(
      statusCode: 401,
      body: '',
      uri: Uri.parse('https://h:8080/upload'),
    );
    final g = mapTransferError(e.toString(), direction: sending);
    expect(g.action, TransferErrorAction.retryOrRePair);
    expect(g.headline, contains('declined'));
  });

  test('null error, sending -> generic fallback with recorded note', () {
    final g = mapTransferError(null, direction: sending);
    expect(g.headline, 'Transfer failed');
    expect(g.action, TransferErrorAction.retryOrRePair);
    expect(g.raw, 'No error detail was recorded.');
  });

  test('null error, receiving -> no suggested action', () {
    final g = mapTransferError(null, direction: receiving);
    expect(g.action, TransferErrorAction.none);
  });

  test('unrecognized string -> fallback, raw preserved verbatim', () {
    final g = mapTransferError('totally novel error', direction: sending);
    expect(g.headline, 'Transfer failed');
    expect(g.raw, 'totally novel error');
  });
}
