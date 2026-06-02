import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../pairing/devices_screen.dart';

/// Doc-gap feature (architecture.md transport rule #4 / ux.md pairing rule
/// #4): when a previous launch's pair handshake was killed mid-confirm, the
/// persisted mailbox still holds the in-flight marker. We surface a
/// one-shot, dismissible prompt rather than auto-resuming (resuming a
/// half-done handshake is unsafe — the peer has moved on). A banner, not a
/// startup dialog, so the share path is never blocked: a user who launched
/// to SHARE shouldn't have to dismiss a modal first.
///
/// Dismiss is local UI state — the marker itself is consumed (purged) on
/// first detect, so it can't reappear next launch and needs no provider.
class InterruptedPairingBanner extends ConsumerStatefulWidget {
  const InterruptedPairingBanner({super.key});

  @override
  ConsumerState<InterruptedPairingBanner> createState() =>
      _InterruptedPairingBannerState();
}

class _InterruptedPairingBannerState
    extends ConsumerState<InterruptedPairingBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final marker = ref.watch(interruptedPairingProvider).value;
    if (marker == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link_off, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Previous pairing was interrupted',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Pairing with ${marker.peerName} didn't finish. Re-pair to try "
            'again.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _dismissed = true),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onErrorContainer,
                ),
                child: const Text('Dismiss'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: () {
                  setState(() => _dismissed = true);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DevicesScreen(),
                    ),
                  );
                },
                child: const Text('Re-pair'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
