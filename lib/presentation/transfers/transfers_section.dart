import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/transfer.dart';

/// Compact list of in-flight + recently-completed transfers, rendered
/// below the peer list on the home screen. Also pops a snackbar when an
/// incoming transfer completes (so the user notices the new file even
/// if they aren't looking at this section).
class TransfersSection extends ConsumerStatefulWidget {
  const TransfersSection({super.key});

  @override
  ConsumerState<TransfersSection> createState() => _TransfersSectionState();
}

class _TransfersSectionState extends ConsumerState<TransfersSection> {
  /// IDs of incoming transfers we've already announced via snackbar so
  /// we don't re-announce on every list rebuild.
  final Set<String> _announced = {};

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<Transfer>>>(transfersStreamProvider,
        (_, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      for (final t in list) {
        if (t.direction == TransferDirection.receiving &&
            t.status == TransferStatus.completed &&
            _announced.add(t.id)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Received ${t.fileName} from ${t.peerName} → ${t.savedPath ?? "Downloads"}',
              ),
            ),
          );
        }
      }
    });

    final transfers = ref.watch(transfersStreamProvider).valueOrNull ?? const [];
    if (transfers.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visible = transfers.take(5).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text('Transfers', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...visible.map((t) => _TransferTile(transfer: t)),
      ],
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSend = transfer.direction == TransferDirection.sending;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSend ? Icons.upload : Icons.download,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _StatusPill(status: transfer.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              isSend
                  ? 'to ${transfer.peerName}'
                  : 'from ${transfer.peerName}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (transfer.status == TransferStatus.inProgress ||
                transfer.status == TransferStatus.pending) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: transfer.totalBytes > 0 ? transfer.progress : null,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _progressLabel(transfer),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
            if (transfer.status == TransferStatus.failed &&
                transfer.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                transfer.errorMessage!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _progressLabel(Transfer t) {
    final done = _formatBytes(t.bytesTransferred);
    final total = t.totalBytes > 0 ? _formatBytes(t.totalBytes) : '?';
    final pct =
        t.totalBytes > 0 ? ' (${(t.progress * 100).toStringAsFixed(0)}%)' : '';
    return '$done / $total$pct';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final TransferStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bg, fg) = switch (status) {
      TransferStatus.pending => (
          'Queued',
          theme.colorScheme.surfaceContainerHighest,
          theme.colorScheme.onSurfaceVariant
        ),
      TransferStatus.inProgress => (
          'Sending',
          theme.colorScheme.primaryContainer,
          theme.colorScheme.onPrimaryContainer
        ),
      TransferStatus.completed => (
          'Done',
          theme.colorScheme.tertiaryContainer,
          theme.colorScheme.onTertiaryContainer
        ),
      TransferStatus.failed => (
          'Failed',
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer
        ),
      TransferStatus.cancelled => (
          'Cancelled',
          theme.colorScheme.surfaceContainerHighest,
          theme.colorScheme.onSurfaceVariant
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}
