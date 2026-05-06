import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Slice 5.5: top-of-home banner shown while files received from the
/// OS share-sheet are waiting for the user to pick a destination peer.
/// Tapping a paired peer in the list below sends the queued files to
/// that peer instead of opening the file picker (handled in
/// `home_screen.dart`).
class SharePendingBanner extends ConsumerWidget {
  const SharePendingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingSharesProvider);
    final pending = pendingAsync.value;
    if (pending == null || pending.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final n = pending.files.length;
    final label = n == 1
        ? 'Sharing ${pending.files.single.name}'
        : 'Sharing $n files';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(Icons.outgoing_mail,
                    color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap a paired device below to send.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer
                              .withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  color: theme.colorScheme.onPrimaryContainer,
                  onPressed: () =>
                      ref.read(pendingSharesControllerProvider).clear(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
