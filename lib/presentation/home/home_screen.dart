import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../app/providers.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../pairing/devices_screen.dart';
import '../pairing/invite_controller.dart';
import '../pairing/pair_invite_modal.dart';
import '../pairing/show_pair_screen.dart';
import '../transfers/transfers_section.dart';
import 'battery_optimization_banner.dart';
import 'quiet_mode_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Track invite ids we've already opened a modal for so we don't
  /// double-open on every status emission.
  final _modalShownFor = <String>{};

  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(peersStreamProvider);
    final theme = Theme.of(context);

    // Surface inbound (responder-side) invites as soon as the service
    // emits an awaitingFingerprint event. We don't show modals for
    // initiator-side invites here — the home_screen / peer-tap path
    // opens those itself, so it controls the modal lifecycle.
    ref.listen(pairInviteStreamProvider, (_, next) {
      next.whenData((invite) {
        if (invite.role != PairInviteRole.responder) return;
        if (invite.status != PairInviteStatus.awaitingFingerprint) return;
        if (!_modalShownFor.add(invite.inviteId)) return;
        // Try to find the inbound peer in the discovered list so we
        // can route /pair-finalize back at them. If they're not in the
        // list (yet), the controller still updates local state — the
        // peer's TTL will take care of cleanup.
        final peers = ref.read(peersStreamProvider).value ?? const [];
        final peer = peers.where((p) => p.id == invite.peerId).firstOrNull;
        PairInviteModal.show(context, invite: invite, peer: peer);
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sharer'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.devices),
            tooltip: 'Paired devices',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DevicesScreen(),
              ),
            ),
          ),
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
              const BatteryOptimizationBanner(),
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
    final pairedIds = ref.watch(pairedDeviceIdsProvider);
    final isPaired = pairedIds.contains(peer.id);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.devices,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Row(
          children: [
            Flexible(child: Text(peer.name)),
            if (isPaired) ...[
              const SizedBox(width: 8),
              Icon(Icons.verified_user,
                  size: 16, color: theme.colorScheme.primary),
            ],
          ],
        ),
        subtitle:
            Text(peer.isReachable ? '${peer.host}:${peer.port}' : 'Resolving…'),
        trailing: const Icon(Icons.send),
        onTap: peer.isReachable
            ? () => _onTap(context, ref, isPaired: isPaired)
            : null,
      ),
    );
  }

  Future<void> _onTap(
    BuildContext context,
    WidgetRef ref, {
    required bool isPaired,
  }) async {
    if (!isPaired) {
      await _showPairFirstSheet(context, ref);
      return;
    }
    await _pickAndSend(context, ref);
  }

  Future<void> _showPairFirstSheet(BuildContext context, WidgetRef ref) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.lock_outline,
                  size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('Pair with ${peer.name} first',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Devices need to pair once before sharing files. After '
                'pairing, you can transfer freely on any network.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.send_to_mobile),
                label: const Text('Send pair invite'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  _sendInvite(context, ref);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Use QR code instead'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ShowPairScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                icon: const Icon(Icons.devices),
                label: const Text('Open Devices'),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DevicesScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendInvite(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(inviteControllerProvider);
    final outcome = await controller.invite(peer);
    if (!context.mounted) return;
    switch (outcome) {
      case InviteLaunched(:final invite):
        await PairInviteModal.show(context, invite: invite, peer: peer);
      case InviteFailed(:final message):
        _toast(context, message);
    }
  }

  Future<void> _pickAndSend(BuildContext context, WidgetRef ref) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        withReadStream: true,
        allowMultiple: true,
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, 'File picker error: $e');
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final transferService = ref.read(transferServiceProvider);
    var queued = 0;
    var skipped = 0;
    for (final picked in result.files) {
      final stream = picked.readStream;
      if (stream == null) {
        skipped++;
        continue;
      }
      final payload = FilePayload(
        fileName: picked.name,
        sizeBytes: picked.size,
        bytes: stream,
        mimeType: lookupMimeType(picked.name),
      );
      try {
        await transferService.send(peer: peer, file: payload);
        queued++;
      } catch (_) {
        skipped++;
      }
    }
    if (!context.mounted) return;
    if (queued == 0) {
      _toast(context, 'No files could be sent.');
    } else if (queued == 1 && skipped == 0) {
      _toast(context,
          'Sending ${result.files.first.name} → ${peer.name}…');
    } else {
      _toast(
        context,
        'Sending $queued file${queued == 1 ? '' : 's'} → ${peer.name}'
        '${skipped > 0 ? ' ($skipped skipped)' : ''}…',
      );
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
