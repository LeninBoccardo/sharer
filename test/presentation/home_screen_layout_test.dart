import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/app.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/transfer.dart';

import '../fakes/fake_mdns_backend.dart';
import '../fakes/fake_network_source.dart';
import '../fakes/fake_transfer_service.dart';

void main() {
  testWidgets(
      'home screen does not overflow on a small viewport with many transfers',
      (tester) async {
    // Tight viewport that's well below the natural height of header +
    // empty state + 10 transfer cards. With the slice 3.1 fix this
    // should scroll instead of overflowing.
    await tester.binding.setSurfaceSize(const Size(600, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final manyTransfers = List.generate(
      10,
      (i) => Transfer(
        id: 'id-$i',
        peerId: 'peer-$i',
        peerName: 'Peer $i',
        fileName: 'file-$i.bin',
        totalBytes: 1000,
        bytesTransferred: 1000,
        direction: TransferDirection.sending,
        status: TransferStatus.completed,
        startedAt: DateTime.utc(2026, 5, 4).add(Duration(seconds: i)),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          mdnsBackendProvider.overrideWithValue(FakeMdnsBackend()),
          networkSourceProvider
              .overrideWith((ref) => FakeNetworkSource(initial: null)),
          transferServiceProvider
              .overrideWithValue(FakeTransferService(manyTransfers)),
        ],
        child: const SharerApp(),
      ),
    );
    await tester.pumpAndSettle();

    // No RenderFlex overflow exception was thrown during layout.
    expect(tester.takeException(), isNull);

    // The body provides a scroll view, so the user can reach content
    // below the fold.
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
