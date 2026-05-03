import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/peer.dart';
import 'quiet_mode_banner.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peersAsync = ref.watch(peersStreamProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sharer'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const QuietModeBanner(),
              Text('Nearby devices', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Expanded(
                child: peersAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Error: $e')),
                  data: (peers) => peers.isEmpty
                      ? const _EmptyState()
                      : _PeerList(peers: peers),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_other, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('No devices found yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Devices on the same Wi-Fi running Sharer will appear here.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PeerList extends StatelessWidget {
  const _PeerList({required this.peers});

  final List<Peer> peers;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _PeerTile(peer: peers[i]),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.devices, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(peer.name),
        subtitle: Text(peer.isReachable ? '${peer.host}:${peer.port}' : 'Resolving…'),
        trailing: peer.isPaired
            ? Icon(Icons.verified_user, color: theme.colorScheme.primary)
            : null,
      ),
    );
  }
}
