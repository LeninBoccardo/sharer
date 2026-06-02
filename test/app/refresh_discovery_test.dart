import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sharer/app/providers.dart';
import 'package:sharer/data/network/network_source.dart';
import 'package:sharer/domain/entities/network_info.dart';
import 'package:sharer/domain/entities/peer.dart';
import 'package:sharer/domain/repositories/peer_discovery_repository.dart';

/// Records refreshAnnouncement() so we can assert the burst fired.
class _SpyDiscovery implements PeerDiscoveryRepository {
  int refreshCount = 0;

  @override
  Future<void> refreshAnnouncement() async => refreshCount++;

  @override
  Stream<List<Peer>> watchPeers() => const Stream<List<Peer>>.empty();

  @override
  Stream<bool> watchAnnouncing() => const Stream<bool>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// Counts read() calls so we can assert NetworkWatcher.recheck() re-sampled.
class _CountingNetworkSource implements NetworkSource {
  int readCount = 0;
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> connectivityChanges() => _changes.stream;

  @override
  Future<NetworkInfo?> read() async {
    readCount++;
    return null;
  }
}

void main() {
  testWidgets(
      'refreshDiscovery re-samples the network (recheck) and re-advertises '
      '(refreshAnnouncement)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final spy = _SpyDiscovery();
    final source = _CountingNetworkSource();

    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          peerDiscoveryProvider.overrideWithValue(spy),
          networkSourceProvider.overrideWith((_) => source),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );

    // Construct the watcher + let its initial sample settle, then baseline
    // the read count so the assertion proves recheck() — not construction —
    // re-sampled.
    capturedRef.read(networkWatcherProvider);
    await tester.pump();
    final baseline = source.readCount;

    await refreshDiscovery(capturedRef);

    expect(spy.refreshCount, 1, reason: 'refreshAnnouncement fired exactly once');
    expect(source.readCount, greaterThan(baseline),
        reason: 'recheck() re-sampled the network before re-advertising');
  });
}
