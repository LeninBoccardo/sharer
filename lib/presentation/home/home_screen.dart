import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../app/providers.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/peer.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../transfers/transfers_section.dart';
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
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'You & networks',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DiagnosticsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        // Single scrollable column: peer area and transfers compete for
        // height inside an Expanded otherwise (caused a 7.7px overflow on
        // small screens once the Transfers section started rendering).
        // Now growth in either pushes content down rather than getting
        // squeezed.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const QuietModeBanner(),
              Text('Nearby devices', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              peersAsync.when(
                loading: () => const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => SizedBox(
                  height: 120,
                  child: Center(child: Text('Error: $e')),
                ),
                data: (peers) =>
                    peers.isEmpty ? const _EmptyState() : _PeerList(peers: peers),
              ),
              const TransfersSection(),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_other, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('No devices found yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Devices on the same Wi-Fi running Sharer will appear here.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
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
    // Render inline so the parent SingleChildScrollView owns the scroll;
    // a nested ListView here would conflict.
    return Column(
      children: [
        for (var i = 0; i < peers.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _PeerTile(peer: peers[i]),
        ],
      ],
    );
  }
}

class _PeerTile extends ConsumerWidget {
  const _PeerTile({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.devices,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(peer.name),
        subtitle:
            Text(peer.isReachable ? '${peer.host}:${peer.port}' : 'Resolving…'),
        trailing: peer.isPaired
            ? Icon(Icons.verified_user, color: theme.colorScheme.primary)
            : const Icon(Icons.send),
        onTap: peer.isReachable ? () => _pickAndSend(context, ref) : null,
      ),
    );
  }

  Future<void> _pickAndSend(BuildContext context, WidgetRef ref) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withReadStream: true);
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, 'File picker error: $e');
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    final stream = picked.readStream;
    if (stream == null) {
      if (!context.mounted) return;
      _toast(context, 'Could not read file (no stream available).');
      return;
    }

    final payload = FilePayload(
      fileName: picked.name,
      sizeBytes: picked.size,
      bytes: stream,
      mimeType: lookupMimeType(picked.name),
    );

    try {
      final transfer =
          await ref.read(transferServiceProvider).send(peer: peer, file: payload);
      if (!context.mounted) return;
      _toast(context, 'Sending ${transfer.fileName} → ${peer.name}…');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, 'Send failed: $e');
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
