import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Shown when the device is on an unrecognized network (Wi-Fi or
/// Ethernet). Per the security model (docs/v1/security.md), discoverability
/// is suppressed on untrusted networks but paired peers can still reach
/// this device — the banner communicates that and offers a one-tap "Trust
/// this network" action.
class QuietModeBanner extends ConsumerWidget {
  const QuietModeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTrusted = ref.watch(isOnTrustedNetworkProvider).value ?? false;
    final network = ref.watch(currentNetworkProvider).value;

    if (isTrusted || network == null || !network.hasNetwork) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_tethering_off, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'On unrecognized network',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Discoverability off. Paired devices can still reach you.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              await ref.read(networkWatcherProvider).trust(network);
            },
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onTertiaryContainer,
            ),
            child: const Text('Trust'),
          ),
        ],
      ),
    );
  }
}
