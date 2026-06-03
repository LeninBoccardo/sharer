import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/transfer/transfer_error_guidance.dart';

/// Opens the failure-detail sheet for [transfer]: file/peer/size/time, the
/// mapped human guidance, an inline Retry (when the source is still
/// re-openable), and a collapsible technical-details tile with the raw error.
/// Follows the existing showModalBottomSheet convention.
Future<void> showTransferDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Transfer transfer,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TransferDetailSheet(transfer: transfer),
  );
}

class _TransferDetailSheet extends ConsumerWidget {
  const _TransferDetailSheet({required this.transfer});

  final Transfer transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = transfer;
    final guidance = mapTransferError(t.errorMessage, direction: t.direction);
    final isSend = t.direction == TransferDirection.sending;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(guidance.headline,
                textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              guidance.detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 20),
            _MetaRow(label: 'File', value: t.fileName),
            _MetaRow(label: isSend ? 'To' : 'From', value: t.peerName),
            _MetaRow(label: 'Size', value: _formatBytes(t.totalBytes)),
            _MetaRow(label: 'Started', value: _formatTime(t.startedAt)),
            if (t.completedAt != null)
              _MetaRow(label: 'Failed', value: _formatTime(t.completedAt!)),
            const SizedBox(height: 16),
            if (t.canRetry)
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () {
                  ref.read(transferServiceProvider).retry(t.id);
                  Navigator.of(context).pop();
                },
              )
            else if (isSend)
              Text(
                'Source no longer available — share or pick the file again.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            const SizedBox(height: 12),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Technical details',
                    style: theme.textTheme.labelLarge),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  SelectableText(
                    guidance.raw,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
