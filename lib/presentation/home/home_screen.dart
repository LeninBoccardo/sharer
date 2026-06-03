import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/pair_invite.dart';
import '../../domain/entities/peer.dart';
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
import 'dropped_file_sender.dart';
import 'interrupted_pairing_banner.dart';
import 'peer_send_coordinator.dart';
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

  // ----- Multi-peer selection (ephemeral UI state; single owner, so no
  // provider — long-press a paired tile to enter, tap tiles to toggle). -----
  final _selectedPeerIds = <String>{};
  bool get _selectionMode => _selectedPeerIds.isNotEmpty;

  void _enterSelection(String id) => setState(() => _selectedPeerIds.add(id));

  void _toggleSelect(String id) => setState(() {
    if (!_selectedPeerIds.remove(id)) _selectedPeerIds.add(id);
  });

  void _clearSelection() {
    if (_selectedPeerIds.isEmpty) return;
    setState(_selectedPeerIds.clear);
  }

  Future<void> _sendToSelected(List<Peer> allPeers) async {
    final selected = [
      for (final p in allPeers)
        if (_selectedPeerIds.contains(p.id) && p.isReachable) p,
    ];
    if (selected.isEmpty) return;
    final ids = await PeerSendCoordinator(ref).sendToPeers(context, selected);
    if (!mounted) return;
    _clearSelection();
    if (ids.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TransferScreen(
          transferIds: ids,
          peerName:
              '${selected.length} device${selected.length == 1 ? '' : 's'}',
        ),
      ),
    );
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

    final allPeers = peersAsync.value ?? const <Peer>[];
    final hasSelectableReachable = allPeers.any(
      (p) => _selectedPeerIds.contains(p.id) && p.isReachable,
    );

    return PopScope(
      // In selection mode, Android back exits selection first.
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _selectionMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel selection',
                  onPressed: _clearSelection,
                ),
                title: Text('${_selectedPeerIds.length} selected'),
              )
            : AppBar(
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
                const InterruptedPairingBanner(),
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
                  data: (peers) => peers.isEmpty
                      ? const _EmptyState()
                      : _PeerList(
                          peers: peers,
                          selectionMode: _selectionMode,
                          selectedIds: _selectedPeerIds,
                          onLongPressPaired: _enterSelection,
                          onToggle: _toggleSelect,
                        ),
                ),
                const TransfersSection(),
              ],
            ),
          ),
        ),
        bottomNavigationBar: _selectionMode
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _clearSelection,
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.send),
                          label: Text('Send to ${_selectedPeerIds.length}'),
                          onPressed: hasSelectableReachable
                              ? () => _sendToSelected(allPeers)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class _EmptyState extends ConsumerStatefulWidget {
  const _EmptyState();

  @override
  ConsumerState<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends ConsumerState<_EmptyState> {
  bool _scanning = false;
  Timer? _scanTimer;

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    // Re-announce + re-listen burst, the same seam the foreground /
    // share-open triggers use. Best-effort: refreshDiscovery is a
    // trust-gated no-op in quiet mode (and before discovery starts), so
    // this is user feedback as much as an actual rescan.
    await refreshDiscovery(ref);
    if (!mounted) return;
    // Keep the spinner up briefly so the tap registers as an action even
    // when discovery had nothing to restart.
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _scanning = false);
    });
  }

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
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            icon: _scanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(_scanning ? 'Scanning…' : 'Scan for new peers'),
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
    );
  }
}

class _PeerList extends ConsumerWidget {
  const _PeerList({
    required this.peers,
    this.selectionMode = false,
    this.selectedIds = const {},
    this.onLongPressPaired,
    this.onToggle,
  });

  final List<Peer> peers;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String)? onLongPressPaired;
  final void Function(String)? onToggle;

  /// Stable, value-equal signature of how [peers] partitions by paired
  /// membership. Watched via `.select` so the list re-partitions only when
  /// the partition would actually change — NOT on every identity-equal
  /// pairedDeviceIdsProvider emit (preserves audit #43).
  String _partitionKey(Set<String> pairedIds) {
    final paired = [
      for (final p in peers)
        if (pairedIds.contains(p.id)) p.id,
    ]..sort();
    return paired.join(',');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The `.select` gates the rebuild (fires only when the signature
    // changes); the trailing ref.read just fetches the current Set to do
    // the O(n) split. Reading adds no subscription, so it cannot cause
    // extra rebuilds — the select is the gate. Do NOT collapse this to
    // ref.watch(pairedDeviceIdsProvider): that reintroduces the whole-list
    // rebuild audit #43 removed (the provider hands back a fresh,
    // identity-equal Set on every paired-devices emit).
    ref.watch(pairedDeviceIdsProvider.select(_partitionKey));
    final pairedIds = ref.read(pairedDeviceIdsProvider);
    final paired = [
      for (final p in peers)
        if (pairedIds.contains(p.id)) p,
    ];
    final nearby = [
      for (final p in peers)
        if (!pairedIds.contains(p.id)) p,
    ];

    // Favorited paired peers lead the Paired section. Watch only a signature
    // of the favorites among the *visible paired* peers, so a favorite toggle
    // re-sorts exactly once and an unrelated toggle doesn't rebuild the list
    // (audit #43). Partition-concat (not List.sort, which is unstable) keeps
    // discovery order within each group.
    ref.watch(
      favoriteDeviceIdsProvider.select(
        (favs) => ([
          for (final p in paired)
            if (favs.contains(p.id)) p.id,
        ]..sort()).join(','),
      ),
    );
    final favs = ref.read(favoriteDeviceIdsProvider);
    final orderedPaired = [
      for (final p in paired)
        if (favs.contains(p.id)) p,
      for (final p in paired)
        if (!favs.contains(p.id)) p,
    ];

    // Render inline so the parent SingleChildScrollView owns the scroll;
    // a nested ListView here would conflict.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (orderedPaired.isNotEmpty) ...[
          const _SectionHeader(label: 'Paired'),
          for (var i = 0; i < orderedPaired.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _PeerTile(
              peer: orderedPaired[i],
              selectionMode: selectionMode,
              isSelected: selectedIds.contains(orderedPaired[i].id),
              selectable: true,
              onLongPressSelect: onLongPressPaired,
              onToggleSelect: onToggle,
            ),
          ],
        ],
        if (paired.isNotEmpty && nearby.isNotEmpty) const SizedBox(height: 16),
        if (nearby.isNotEmpty) ...[
          const _SectionHeader(label: 'Nearby (not paired)'),
          for (var i = 0; i < nearby.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _PeerTile(
              peer: nearby[i],
              selectionMode: selectionMode,
              selectable: false,
              onLongPressSelect: onLongPressPaired,
              onToggleSelect: onToggle,
            ),
          ],
        ],
      ],
    );
  }
}

/// Desktop drag-and-drop wrapper for a single paired peer tile. Built ONLY
/// when [isDesktopDropSupported] (Windows/macOS/Linux), so the DropTarget +
/// desktop_drop are never in the mobile/web tree. Dropping one or more files
/// streams a [FilePayload] per file from disk and sends to [peer] via the same
/// transferServiceProvider.send path as a tap (zero extra taps), then pushes
/// the scoped TransferScreen. Hover state is local to this widget's State so it
/// never lifts a rebuild to the peer list (preserves audit #43).
class _PeerDropTarget extends ConsumerStatefulWidget {
  const _PeerDropTarget({required this.peer, required this.child});

  final Peer peer;
  final Widget child;

  @override
  ConsumerState<_PeerDropTarget> createState() => _PeerDropTargetState();
}

class _PeerDropTargetState extends ConsumerState<_PeerDropTarget> {
  bool _hovering = false;

  Future<void> _onDragDone(DropDoneDetails detail) async {
    if (mounted) setState(() => _hovering = false);
    final specs = <DroppedFileSpec>[
      for (final x in detail.files)
        DroppedFileSpec(path: x.path, name: x.name, size: await x.length()),
    ];
    if (specs.isEmpty) return;
    final result = await sendDroppedFiles(
      service: ref.read(transferServiceProvider),
      peer: widget.peer,
      files: specs,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result.queued == 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No files could be sent.')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Sending ${result.queued} file${result.queued == 1 ? '' : 's'} '
          '→ ${widget.peer.name}'
          '${result.skipped > 0 ? ' (${result.skipped} skipped)' : ''}…',
        ),
      ),
    );
    if (result.started.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TransferScreen(
          transferIds: result.started,
          peerName: widget.peer.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: _onDragDone,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovering ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

class _PeerTile extends ConsumerWidget {
  const _PeerTile({
    required this.peer,
    this.selectionMode = false,
    this.isSelected = false,
    this.selectable = false,
    this.onLongPressSelect,
    this.onToggleSelect,
  });

  final Peer peer;
  final bool selectionMode;
  final bool isSelected;
  final bool selectable;
  final void Function(String)? onLongPressSelect;
  final void Function(String)? onToggleSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Audit #43: select the per-peer bool so this tile only rebuilds when
    // *its own* paired status flips — not on every paired-devices emit
    // (pairedDeviceIdsProvider hands back a fresh, identity-equal Set).
    final isPaired = ref.watch(
      pairedDeviceIdsProvider.select((ids) => ids.contains(peer.id)),
    );
    // a11y: announce the tile as one coherent node so paired/reachable state
    // is never conveyed by color/icon alone. excludeSemantics is NOT set, so
    // the ListTile's own "tap to send" button semantics still merge in.
    final tileSemantics =
        '${peer.name}, ${isPaired ? 'paired' : 'not paired'}, '
        '${peer.isReachable ? 'reachable' : 'resolving address'}';
    // Favorite + saved-address hint are paired-only and per-tile (.select /
    // family key) so they never widen the list rebuild (audit #43).
    final isFav = isPaired
        ? ref.watch(
            favoriteDeviceIdsProvider.select((ids) => ids.contains(peer.id)),
          )
        : false;
    final savedAddress = isPaired
        ? (ref.watch(peerReachableViaCacheProvider(peer.id)).value ?? false)
        : false;
    final tile = Semantics(
      container: true,
      label: tileSemantics,
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.devices,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          title: Row(
            children: [
              Flexible(child: Text(peer.name)),
              const SizedBox(width: 8),
              // Both states carry a distinct SHAPE + Semantics label, so
              // paired vs not-paired never relies on color alone.
              if (isPaired)
                Semantics(
                  label: 'Paired',
                  child: Icon(
                    Icons.verified_user,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                )
              else
                Semantics(
                  label: 'Not paired',
                  child: Icon(
                    Icons.lock_open_outlined,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
          isThreeLine: savedAddress,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                peer.isReachable ? '${peer.host}:${peer.port}' : 'Resolving…',
              ),
              // "Saved address": we hold a fresh cached IP for this paired
              // peer, so a send will likely connect fast even before mDNS.
              if (savedAddress)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bookmark_outline,
                      size: 14,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Saved address',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          trailing: (selectionMode && selectable)
              ? Checkbox(
                  value: isSelected,
                  onChanged: peer.isReachable
                      ? (_) => onToggleSelect?.call(peer.id)
                      : null,
                )
              : (isPaired
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // IconButton absorbs its own tap, so toggling the pin
                          // does NOT bubble to ListTile.onTap (the send path).
                          IconButton(
                            icon: Icon(
                              isFav ? Icons.star : Icons.star_border,
                              size: 20,
                              color: isFav
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                            tooltip: isFav ? 'Unpin' : 'Pin to top',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => ref
                                .read(favoriteDeviceIdsProvider.notifier)
                                .toggle(peer.id),
                          ),
                          const Icon(Icons.send),
                        ],
                      )
                    : const Icon(Icons.send)),
          selected: selectionMode && isSelected,
          onTap: selectionMode
              ? ((selectable && peer.isReachable)
                    ? () => onToggleSelect?.call(peer.id)
                    : null)
              : (peer.isReachable
                    ? () => _onTap(context, ref, isPaired: isPaired)
                    : null),
          // Long-press a paired+reachable tile to enter multi-select mode.
          onLongPress: (!selectionMode && selectable && peer.isReachable)
              ? () => onLongPressSelect?.call(peer.id)
              : null,
        ),
      ),
    );

    // Desktop only: arm drag-and-drop send on a paired + reachable tile (and
    // not while multi-selecting). On mobile/web isDesktopDropSupported is false
    // so the tile is byte-identical to before — no DropTarget in the tree, so
    // desktop_drop is never referenced there.
    final canDrop = isDesktopDropSupported &&
        isPaired &&
        peer.isReachable &&
        !selectionMode;
    if (!canDrop) return tile;
    return _PeerDropTarget(peer: peer, child: tile);
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
    // Delegate the send to the shared coordinator (the multi-peer fan-out
    // uses it too). send() is fire-and-forget, so pushing the transfer screen
    // here is decorative — no latency on the share path. Scoped to the ids we
    // started.
    final startedIds = await PeerSendCoordinator(ref).sendToPeer(context, peer);
    if (startedIds.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TransferScreen(transferIds: startedIds, peerName: peer.name),
      ),
    );
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
              Icon(
                Icons.lock_outline,
                size: 40,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Pair with ${peer.name} first',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Devices need to pair once before sharing files. After '
                'pairing, you can transfer freely on any network.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
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

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
