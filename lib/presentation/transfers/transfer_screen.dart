import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/transfer.dart';

/// Dedicated post-tap transfer screen (docs/v1/ux.md primary send flow).
/// Scoped to the [transferIds] started by a peer tap (or a single id when
/// opened from a TransfersSection tile). Purely decorative on the share
/// path: the upload already fired (send() is fire-and-forget) before this
/// route was pushed, so nothing here adds latency.
///
/// Watches [transfersStreamProvider] and filters to the scoped ids client
/// side — no scoped/family provider is introduced (no second caller yet,
/// so that would be premature). The cancel affordance and retry CTA are
/// added by the follow-up commits in this cluster.
class TransferScreen extends ConsumerWidget {
  const TransferScreen({
    super.key,
    required this.transferIds,
    required this.peerName,
  });

  final Set<String> transferIds;
  final String peerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(transfersStreamProvider).value ?? const <Transfer>[];
    final scoped =
        all.where((t) => transferIds.contains(t.id)).toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: Text('Sending to $peerName')),
      body: SafeArea(
        child: scoped.isEmpty
            // The watchAll snapshot lands a frame later than the pushed
            // route in some cases; show a spinner until our ids appear.
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [for (final t in scoped) _TransferCard(transfer: t)],
              ),
      ),
    );
  }
}

class _TransferCard extends ConsumerWidget {
  const _TransferCard({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = transfer;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.fileName,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _SuccessGlyph(status: t.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'to ${t.peerName}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 12),
            if (t.status == TransferStatus.inProgress ||
                t.status == TransferStatus.pending)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: t.totalBytes > 0 ? t.progress : null,
                  minHeight: 8,
                ),
              ),
            if (t.status == TransferStatus.failed)
              Text(
                t.errorMessage ?? 'Transfer failed',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            if (t.status == TransferStatus.cancelled)
              Text(
                'Cancelled',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
          ],
        ),
      ),
    );
  }
}

/// The ~1s "brief success animation" from ux.md: a 200ms scale-in check
/// the [AnimatedSwitcher] mounts when the transfer flips to completed.
/// Auto-dismiss of the whole screen is intentionally NOT wired (it would
/// pop a route the user may be mid-scroll on) — the glyph is the success
/// affordance.
class _SuccessGlyph extends StatelessWidget {
  const _SuccessGlyph({required this.status});

  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: child),
      child: status == TransferStatus.completed
          ? Icon(
              Icons.check_circle,
              key: const ValueKey('done'),
              color: Theme.of(context).colorScheme.tertiary,
            )
          : const SizedBox.shrink(key: ValueKey('pending')),
    );
  }
}
