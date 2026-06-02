import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/domain/entities/paired_device.dart';

// Regression test for audit #43: pairedDeviceIdsProvider hands back a
// fresh, identity-equal Set on every paired-devices emit. A consumer
// that watches the whole Set rebuilds on EVERY emit (once per peer
// tile). The fix is to `.select` the scalar each consumer needs; the
// selected bool has value-equality, so identical-content emits must NOT
// rebuild the widget, while a genuine membership change still does.

PairedDevice _device(String id) => PairedDevice(
      deviceId: id,
      displayName: id,
      psk: Uint8List(32),
      publicKey: Uint8List(32),
      pairedAt: DateTime(2026, 5, 5),
    );

class _CountingTile extends ConsumerWidget {
  const _CountingTile({required this.peerId, required this.onBuild});

  final String peerId;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild();
    final isPaired = ref.watch(
      pairedDeviceIdsProvider.select((ids) => ids.contains(peerId)),
    );
    return Text(isPaired ? 'paired' : 'unpaired',
        textDirection: TextDirection.ltr);
  }
}

void main() {
  testWidgets(
    'a .select consumer does not rebuild when paired membership is unchanged '
    'but rebuilds when it actually changes (audit #43)',
    (tester) async {
      final controller = StreamController<List<PairedDevice>>();
      addTearDown(controller.close);

      var builds = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pairedDevicesStreamProvider.overrideWith((ref) => controller.stream),
          ],
          child: _CountingTile(peerId: 'peer-a', onBuild: () => builds++),
        ),
      );
      // Initial build (stream has not emitted yet — provider seeds {}).
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(find.text('unpaired'), findsOneWidget);

      // First real emit: peer-a is now paired -> the selected bool flips,
      // so the tile MUST rebuild. (pumpAndSettle so the StreamProvider
      // event fully propagates through Riverpod before we assert.)
      controller.add([_device('peer-a')]);
      await tester.pumpAndSettle();
      expect(builds, 2);
      expect(find.text('paired'), findsOneWidget);

      // Second emit: a *distinct* list instance with identical membership
      // for peer-a (peer-b added does not affect peer-a's bool). Before
      // the fix, watching the whole Set rebuilt here; with .select the
      // selected bool is unchanged, so NO rebuild.
      controller.add([_device('peer-a'), _device('peer-b')]);
      await tester.pumpAndSettle();
      expect(builds, 2, reason: 'identical selected bool must not rebuild');

      // Third emit: peer-a removed -> bool flips back -> rebuild.
      controller.add([_device('peer-b')]);
      await tester.pumpAndSettle();
      expect(builds, 3);
      expect(find.text('unpaired'), findsOneWidget);
    },
  );
}
