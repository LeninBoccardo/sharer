import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/transfer/transfer_error_guidance.dart';
import 'transfer_detail_sheet.dart';
import 'transfer_rate_line.dart';

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
      final list = next.value;
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
      // Drop IDs for transfers that have aged out of the list so the
      // dedupe set tracks only currently-visible transfers and cannot
      // grow without bound over a long session (audit #42).
      _announced.retainAll(list.map((t) => t.id));
    });

    final transfers = ref.watch(transfersStreamProvider).value ?? const [];
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

class _TransferTile extends ConsumerWidget {
  const _TransferTile({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              // Live throughput + ETA (renders nothing until it has a rate).
              TransferRateLine(transfer: transfer),
              // Only outgoing transfers can be cancelled; cancel() is a
              // no-op for incoming (driven by the server) per audit #28.
              if (isSend)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancel'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () =>
                        ref.read(transferServiceProvider).cancel(transfer.id),
                  ),
                ),
            ],
            if (transfer.status == TransferStatus.failed) ...[
              const SizedBox(height: 6),
              Text(
                mapTransferError(transfer.errorMessage,
                        direction: transfer.direction)
                    .headline,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      showTransferDetailSheet(context, ref, transfer),
                  child: const Text('Details'),
                ),
              ),
            ],
            // A received file: Open / Reveal / Share onward. Received
            // transfers only ever appear here (TransferScreen is send-only).
            if (!isSend &&
                transfer.status == TransferStatus.completed &&
                transfer.savedPath != null) ...[
              const SizedBox(height: 8),
              _ReceivedActions(savedPath: transfer.savedPath!),
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

/// Open / Reveal / Share-onward actions for a completed received file. Calls
/// through receivedFileActionsProvider so this widget stays free of
/// open_filex / share_plus / dart:io.
class _ReceivedActions extends ConsumerWidget {
  const _ReceivedActions({required this.savedPath});

  final String savedPath;

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(receivedFileActionsProvider);
    final isContentUri = savedPath.startsWith('content://');

    Future<void> run(Future<void> Function() op, String failMsg) async {
      try {
        await op();
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failMsg)));
      }
    }

    final style = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );

    return Wrap(
      spacing: 4,
      children: [
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Open'),
          style: style,
          onPressed: () =>
              run(() => actions.open(savedPath), "Couldn't open the file"),
        ),
        // Reveal-in-folder is desktop-only (no reliable mobile intent).
        if (_isDesktop)
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Reveal'),
            style: style,
            onPressed: () => run(
                () => actions.reveal(savedPath), "Couldn't reveal the file"),
          ),
        // share_plus needs a real file path; hide for content:// URIs.
        if (!isContentUri)
          Builder(
            builder: (btnCtx) => TextButton.icon(
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('Share'),
              style: style,
              onPressed: () {
                final box = btnCtx.findRenderObject() as RenderBox?;
                final origin = (box != null && box.hasSize)
                    ? box.localToGlobal(Offset.zero) & box.size
                    : null;
                run(() => actions.shareOnward(savedPath, origin: origin),
                    "Couldn't share the file");
              },
            ),
          ),
      ],
    );
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
