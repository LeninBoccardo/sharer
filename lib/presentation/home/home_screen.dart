import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../app/providers.dart';
import '../../data/share/incoming_share_service.dart';
import '../../domain/entities/file_payload.dart';
import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/transfer.dart';
import '../../domain/repositories/transfer_service.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../pairing/devices_screen.dart';
import '../../data/security/invite_controller.dart';
import '../pairing/pair_invite_modal.dart';
import '../pairing/show_pair_screen.dart';
import '../share/pending_shares_controller.dart';
import '../share/share_pending_banner.dart';
import '../transfers/transfer_screen.dart';
import '../transfers/transfers_section.dart';
import 'battery_optimization_banner.dart';
import 'quiet_mode_banner.dart';
import 'web_native_app_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Track invite ids we've already opened a modal for so we don't
  /// double-open on every status emission.
  final _modalShownFor = <String>{};

  /// Whether we've already fired an announce-burst for the current
  /// non-empty pending-shares window. Re-armed when the queue clears so a
  /// second share later in the session triggers a fresh burst.
  bool _pendingBurstFired = false;

  @override
  void initState() {
    super.initState();
    // Hot-path 3(c) / CLAUDE.md principle #3: kick a fresh announce+listen
    // burst the moment the share UI opens with files already waiting (a
    // cold-start share). Post-frame so the provider is readable after the
    // first build; the ref.listen in build() covers shares that arrive
    // while we're already open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeBurstForPending(ref.read(pendingSharesProvider).value);
    });
  }

  /// Fires a single discovery burst when the pending-shares queue goes
  /// empty -> non-empty (the user just shared into Sharer), and re-arms
  /// once it clears. refreshDiscovery is itself trust-gated + idempotent,
  /// so this is a no-op on an untrusted network.
  void _maybeBurstForPending(PendingShares? shares) {
    final hasPending = shares != null && shares.isNotEmpty;
    if (hasPending && !_pendingBurstFired) {
      _pendingBurstFired = true;
      unawaited(refreshDiscovery(ref));
    } else if (!hasPending) {
      _pendingBurstFired = false;
    }
  }

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
        // Slice 5.x.3.7: prune the dedup set on terminal states so a
        // peer that re-pairs after declined/expired/completed gets a
        // fresh modal. Previously the id stuck around forever and any
        // re-invite (or modal dismissed by rotation / cold-restart
        // racing this listener) was silently suppressed.
        if (invite.status == PairInviteStatus.declined ||
            invite.status == PairInviteStatus.expired ||
            invite.status == PairInviteStatus.completed) {
          _modalShownFor.remove(invite.inviteId);
          return;
        }
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

    // Announce-burst when a share arrives while the home screen is already
    // open (the cold-start case is handled by the post-frame check in
    // initState). Fires once per empty -> non-empty transition.
    ref.listen(pendingSharesProvider, (_, next) {
      _maybeBurstForPending(next.value);
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
              const WebNativeAppBanner(),
              const QuietModeBanner(),
              const BatteryOptimizationBanner(),
              const SharePendingBanner(),
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
    // Audit #43: select the per-peer bool so this tile only rebuilds when
    // *its own* paired status flips — not on every paired-devices emit
    // (pairedDeviceIdsProvider hands back a fresh, identity-equal Set).
    final isPaired = ref
        .watch(pairedDeviceIdsProvider.select((ids) => ids.contains(peer.id)));
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
    // Slice 5.5: if files arrived via the OS share-sheet, route them
    // here instead of opening the file picker. Lets the user share
    // *into* Sharer with a single tap on the destination peer.
    final pending = ref.read(pendingSharesProvider).value;
    final Set<String> startedIds;
    if (pending != null && pending.isNotEmpty) {
      startedIds = await _sendPending(context, ref, pending.files);
    } else {
      startedIds = await _pickAndSend(context, ref);
    }
    // The upload(s) are already streaming (send() is fire-and-forget), so
    // pushing the transfer screen here is decorative — it adds no latency
    // to the share path. Scoped to just the ids we started.
    if (startedIds.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          TransferScreen(transferIds: startedIds, peerName: peer.name),
    ));
  }

  /// Returns the ids of the transfers it started (for the transfer screen
  /// to scope to); empty when nothing was queued.
  Future<Set<String>> _sendPending(
    BuildContext context,
    WidgetRef ref,
    List<IncomingSharedFile> files,
  ) async {
    final transferService = ref.read(transferServiceProvider);
    final pendingController = ref.read(pendingSharesControllerProvider);
    var queued = 0;
    var skipped = 0;
    final started = <String>{};
    final deleteImmediately = <String>[];
    for (final shared in files) {
      try {
        final file = File(shared.path);
        if (!await file.exists()) {
          // Nothing to drain — safe to drop the (already-missing) path.
          deleteImmediately.add(shared.path);
          skipped++;
          continue;
        }
        final payload = FilePayload(
          fileName: shared.name,
          sizeBytes: shared.size,
          bytes: file.openRead(),
          mimeType: shared.mimeType ?? lookupMimeType(shared.name),
        );
        // Audit #5: send() is fire-and-forget and opens file.openRead()
        // lazily, deep inside the upload after the TLS handshake. We must
        // NOT delete the cached file until the transfer has drained it,
        // so defer the delete until this transfer reaches a terminal
        // status (completed/failed) on watchAll().
        final transfer = await transferService.send(
          peer: peer,
          file: payload,
          // Phase 4 (retry): the cached share file stays on disk until a
          // completed/cancelled settle (see _deleteWhenDrained), so a
          // failed send can re-open it from zero.
          reopen: () => File(shared.path).openRead(),
        );
        started.add(transfer.id);
        unawaited(_deleteWhenDrained(
          transferService,
          pendingController,
          transfer.id,
          shared.path,
        ));
        queued++;
      } catch (_) {
        // Wrapping/queuing failed before the stream was handed off, so
        // nothing will read the file — drop it now.
        deleteImmediately.add(shared.path);
        skipped++;
      }
    }
    // Reset the banner/pending state immediately so the UI flow proceeds,
    // but leave queued files on disk for their deferred per-transfer
    // delete. Eagerly reap only files never handed to a transfer.
    pendingController.clearState();
    await pendingController.deleteFiles(deleteImmediately);
    if (!context.mounted) return started;
    if (queued == 0) {
      _toast(context, 'Could not send shared files.');
    } else if (queued == 1 && skipped == 0) {
      _toast(context, 'Sending ${files.first.name} → ${peer.name}…');
    } else {
      _toast(
        context,
        'Sending $queued file${queued == 1 ? '' : 's'} → ${peer.name}'
        '${skipped > 0 ? ' ($skipped skipped)' : ''}…',
      );
    }
    return started;
  }

  /// Audit #5 + Phase 4 (retry): wait for [transferId] to drain, then
  /// delete the cached share file. The drain signal is `completed` OR
  /// `cancelled` — deliberately NOT `failed`: a failed share send keeps its
  /// cache file so the user can retry from zero (retry re-opens it). A
  /// permanently-failed-and-never-retried file is reaped by the existing
  /// 24h stale-cache sweep in PendingSharesController, so the leak window
  /// is bounded. TransferServiceImpl marks `completed` only after the
  /// upload stream is drained and `cancelled` only after the upload future
  /// settles, so no further reads happen past either. Best-effort: if the
  /// stream closes (app teardown) before then, deleteFiles still runs so we
  /// don't leak the cache.
  Future<void> _deleteWhenDrained(
    TransferService transferService,
    PendingSharesController pendingController,
    String transferId,
    String path,
  ) async {
    try {
      await for (final transfers in transferService.watchAll()) {
        final t = transfers.where((t) => t.id == transferId).firstOrNull;
        if (t != null &&
            (t.status == TransferStatus.completed ||
                t.status == TransferStatus.cancelled)) {
          break;
        }
      }
    } catch (_) {
      // Fall through to delete regardless — a stream error means the
      // upload is no longer running against the file.
    }
    await pendingController.deleteFiles([path]);
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

    // Slice 5.2.4.1.1: show a non-dismissable progress dialog during
    // the network round-trip (createInvite → POST /pair-invite →
    // completeInvite). Without this, the UI is frozen for ~0.5–2 s
    // while the responder's TLS handshake + Ed25519 signing happen
    // and it looks like the app died. Auto-dismissed in the finally
    // block whether the invite succeeds or fails.
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text('Sending pair request to ${peer.name}…')),
          ],
        ),
      ),
    );

    InviteOutcome? outcome;
    try {
      outcome = await controller.invite(peer);
    } finally {
      if (navigator.canPop()) navigator.pop();
    }
    if (!context.mounted) return;
    switch (outcome) {
      case InviteLaunched(:final invite):
        await PairInviteModal.show(context, invite: invite, peer: peer);
      case InviteFailed(:final message):
        _toast(context, message);
    }
  }

  /// Returns the ids of the transfers it started (for the transfer screen
  /// to scope to); empty when nothing was queued.
  Future<Set<String>> _pickAndSend(BuildContext context, WidgetRef ref) async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        withReadStream: true,
        allowMultiple: true,
      );
    } catch (e) {
      if (!context.mounted) return const <String>{};
      _toast(context, 'File picker error: $e');
      return const <String>{};
    }
    if (result == null || result.files.isEmpty) return const <String>{};

    final transferService = ref.read(transferServiceProvider);
    var queued = 0;
    var skipped = 0;
    final started = <String>{};
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
      // Phase 4 (retry): file_picker usually populates picked.path with a
      // cached copy (desktop + most Android); when present, a failed send
      // can be retried by re-opening it. Best-effort — if the copy is gone
      // at retry time the re-stream just fails again. Web has no path, so
      // those transfers are non-retryable.
      final path = picked.path;
      Stream<List<int>> Function()? reopen;
      if (path != null) {
        reopen = () => File(path).openRead();
      }
      try {
        final transfer = await transferService.send(
          peer: peer,
          file: payload,
          reopen: reopen,
        );
        started.add(transfer.id);
        queued++;
      } catch (_) {
        skipped++;
      }
    }
    if (!context.mounted) return started;
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
    return started;
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
