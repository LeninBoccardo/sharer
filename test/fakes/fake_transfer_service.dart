import 'dart:async';

import 'package:sharer/domain/entities/file_payload.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/entities/transfer.dart';
import 'package:sharer/domain/repositories/transfer_service.dart';

class FakeTransferService implements TransferService {
  final List<Transfer> transfers;
  FakeTransferService(this.transfers);

  @override
  Stream<List<Transfer>> watchAll() => Stream<List<Transfer>>.value(transfers);

  @override
  Future<Transfer> send({
    required Peer peer,
    required FilePayload file,
    Stream<List<int>> Function()? reopen,
  }) {
    throw UnimplementedError('send() not used by layout tests');
  }

  @override
  Future<void> cancel(String transferId) async {}

  @override
  Future<void> retry(String transferId) async {}
}
