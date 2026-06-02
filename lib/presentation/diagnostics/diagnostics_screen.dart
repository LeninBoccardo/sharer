import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/device_identity.dart';
import '../../domain/entities/network_info.dart';

class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('You & networks')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            _DeviceCard(),
            SizedBox(height: 16),
            _BroadcastingTile(),
            SizedBox(height: 16),
            _CurrentNetworkCard(),
            SizedBox(height: 24),
            _TrustedNetworksSection(),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final identity = ref.watch(deviceIdentityProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: identity.when(
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('Failed to load identity: $e'),
          data: (id) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.person,
                        color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('This device', style: theme.textTheme.labelSmall),
                        const SizedBox(height: 2),
                        Text(id.name,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Rename',
                    onPressed: () => _renameDialog(context, ref, id),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Mono(
                label: 'Device ID',
                value: id.id,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameDialog(
    BuildContext context,
    WidgetRef ref,
    DeviceIdentity current,
  ) async {
    final controller = TextEditingController(text: current.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Device name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    await ref.read(deviceIdentityRepoProvider).rename(result);
    // Force re-read of cached identity, then re-advertise under the new
    // name IN PLACE. Invalidating peerDiscoveryProvider would dispose the
    // whole discovery object (observer, peer list, announcing stream) just
    // to change the broadcast TXT name (audit #47).
    ref.invalidate(deviceIdentityProvider);
    await ref.read(peerDiscoveryProvider).refreshAnnouncement();
  }
}

class _BroadcastingTile extends ConsumerWidget {
  const _BroadcastingTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final announcing = ref.watch(peerAnnouncingProvider).value ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              announcing ? Icons.podcasts : Icons.podcasts_outlined,
              color: announcing
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Currently broadcasting',
                      style: theme.textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(
                    announcing
                        ? 'Yes — visible to peers on this network.'
                        : 'No — quiet mode. Trust this network to broadcast.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            _Pill(
              label: announcing ? 'On air' : 'Silent',
              bg: announcing
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              fg: announcing
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentNetworkCard extends ConsumerWidget {
  const _CurrentNetworkCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final network = ref.watch(currentNetworkProvider).value;
    final isTrusted = ref.watch(isOnTrustedNetworkProvider).value ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconForLink(network?.linkType),
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('Current network',
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                _TrustBadge(trusted: isTrusted, hasNetwork: network != null),
              ],
            ),
            const SizedBox(height: 12),
            if (network == null || !network.hasNetwork)
              Text(
                'Not connected to a local network.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              )
            else ...[
              _Kv(label: 'Link', value: _labelForLink(network.linkType)),
              const SizedBox(height: 6),
              if (network.linkType == NetworkLinkType.wifi) ...[
                _Kv(label: 'SSID', value: network.ssid ?? '(unknown)'),
                const SizedBox(height: 6),
              ],
              _Kv(label: 'IP', value: network.ipv4 ?? '—'),
              const SizedBox(height: 6),
              _Kv(label: 'Subnet', value: network.subnet ?? '—'),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: isTrusted
                    ? OutlinedButton.icon(
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('Untrust'),
                        onPressed: () =>
                            ref.read(networkWatcherProvider).untrust(network),
                      )
                    : FilledButton.icon(
                        icon: const Icon(Icons.shield),
                        label: const Text('Trust this network'),
                        onPressed: () =>
                            ref.read(networkWatcherProvider).trust(network),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

IconData _iconForLink(NetworkLinkType? t) {
  switch (t) {
    case NetworkLinkType.wifi:
      return Icons.wifi;
    case NetworkLinkType.ethernet:
      return Icons.settings_ethernet;
    case NetworkLinkType.unknown:
    case null:
      return Icons.wifi_off;
  }
}

String _labelForLink(NetworkLinkType t) {
  switch (t) {
    case NetworkLinkType.wifi:
      return 'Wi-Fi';
    case NetworkLinkType.ethernet:
      return 'Ethernet';
    case NetworkLinkType.unknown:
      return 'Unknown';
  }
}

class _TrustedNetworksSection extends ConsumerWidget {
  const _TrustedNetworksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trusted = ref.watch(trustedNetworksProvider).value ?? const {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Trusted networks (${trusted.length})',
            style: theme.textTheme.labelLarge,
          ),
        ),
        const SizedBox(height: 8),
        if (trusted.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'None yet. Trusted networks let Sharer broadcast its presence; paired peers can still reach you on any network.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else
          ...trusted.map((fp) => _TrustedTile(fingerprint: fp)),
      ],
    );
  }
}

class _TrustedTile extends ConsumerWidget {
  const _TrustedTile({required this.fingerprint});

  final String fingerprint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = fingerprint.split('|');
    final ssid = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : '(no SSID)';
    final subnet = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '(no subnet)';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.wifi_lock_outlined),
        title: Text(ssid),
        subtitle: Text(subnet),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove',
          onPressed: () =>
              ref.read(networkWatcherProvider).untrustFingerprint(fingerprint),
        ),
      ),
    );
  }
}

class _TrustBadge extends StatelessWidget {
  const _TrustBadge({required this.trusted, required this.hasNetwork});

  final bool trusted;
  final bool hasNetwork;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!hasNetwork) {
      return _Pill(
        label: 'No Wi-Fi',
        bg: theme.colorScheme.surfaceContainerHighest,
        fg: theme.colorScheme.onSurfaceVariant,
      );
    }
    return trusted
        ? _Pill(
            label: 'Trusted',
            bg: theme.colorScheme.primaryContainer,
            fg: theme.colorScheme.onPrimaryContainer,
          )
        : _Pill(
            label: 'Quiet mode',
            bg: theme.colorScheme.tertiaryContainer,
            fg: theme.colorScheme.onTertiaryContainer,
          );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _Mono extends StatelessWidget {
  const _Mono({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label copied')),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Text('$label: ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            Expanded(
              child: Text(
                value,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.copy, size: 14, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}
