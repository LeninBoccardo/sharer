import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../network/wifi_name_prompt.dart';

/// Just-in-time prompt shown only when the device is on Wi-Fi whose name
/// (SSID) can't be read — the OS gates that read behind location (the
/// ACCESS_FINE_LOCATION runtime grant on Android, the Location privacy
/// setting on Windows). Without it, networks are recognised by IP range
/// alone, so trusted entries show up as "(no SSID)".
///
/// Non-blocking by design (CLAUDE.md #1/#4): it never touches the share path,
/// auto-hides the moment the SSID becomes readable (visibility is reactive on
/// [currentNetworkProvider]), and a "Not now" dismisses it for the session.
class WifiNameBanner extends ConsumerStatefulWidget {
  const WifiNameBanner({super.key});

  @override
  ConsumerState<WifiNameBanner> createState() => _WifiNameBannerState();
}

class _WifiNameBannerState extends ConsumerState<WifiNameBanner> {
  bool _dismissed = false;
  bool _busy = false;

  Future<void> _act() async {
    setState(() => _busy = true);
    try {
      await promptForWifiName(ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final network = ref.watch(currentNetworkProvider).value;
    if (network == null || !network.isUnnamedWifi) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final canRequest =
        ref.read(wifiNamePermissionProvider).supportsRuntimeRequest;
    final body = canRequest
        ? 'Allow location so Sharer can recognise this Wi-Fi by name. '
              'Without it, networks are matched by IP range only.'
        : 'Turn on Location in Windows settings so Sharer can recognise this '
              'Wi-Fi by name. Without it, networks are matched by IP range only.';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_find,
                  color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Wi-Fi name hidden',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => setState(() => _dismissed = true),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                ),
                child: const Text('Not now'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: _busy ? null : _act,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(canRequest ? 'Allow' : 'Open settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
