import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/paired_device.dart';
import 'scan_pair_screen.dart';
import 'show_pair_screen.dart';

/// Lists devices the user has paired and offers the two halves of the
/// pairing flow: show this device's code (initiator), or scan the other
/// device's code (responder).
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairedAsync = ref.watch(pairedDevicesStreamProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: pairedAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (list) => list.isEmpty
                    ? const _EmptyState()
                    : _PairedList(devices: list),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan code'),
                      style: OutlinedButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ScanPairScreen(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Show code'),
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ShowPairScreen(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline,
              size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('No paired devices yet',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Pair a device once and you can share with it on any '
            'network — no need to re-pair on a new Wi-Fi.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PairedList extends ConsumerWidget {
  const _PairedList({required this.devices});

  final List<PairedDevice> devices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final d = devices[i];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.verified_user,
                  color: theme.colorScheme.onPrimaryContainer),
            ),
            title: Text(d.displayName),
            subtitle: Text('Paired ${_relativeTime(d.pairedAt)}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Forget device',
              onPressed: () => _confirmForget(context, ref, d),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmForget(
    BuildContext context,
    WidgetRef ref,
    PairedDevice d,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Forget ${d.displayName}?'),
        content: const Text(
            'You will need to pair again to share files with this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(pairedDevicesRepoProvider).remove(d.deviceId);
    }
  }

  static String _relativeTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }
}
