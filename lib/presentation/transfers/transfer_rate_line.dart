import 'package:flutter/material.dart';

import '../../domain/entities/transfer.dart';
import '../../domain/transfer/transfer_rate.dart' as rate;

/// Live throughput + ETA line ("4.2 MB/s · ~12s left") for an in-flight
/// transfer, shared by the home TransfersSection tile and the dedicated
/// TransferScreen card.
///
/// Keeps a tiny sliding window of (bytes, time) samples so the displayed rate
/// is a smoothed recent value, not the jumpy cumulative average. Rebuild-
/// driven only — no timers, no extra rebuilds: it samples on each build, which
/// already happens only when the throttled (~256 KB) transfer stream emits.
/// Renders nothing until it has a usable rate, so it never adds a blank row.
class TransferRateLine extends StatefulWidget {
  const TransferRateLine({super.key, required this.transfer});

  final Transfer transfer;

  @override
  State<TransferRateLine> createState() => _TransferRateLineState();
}

class _Sample {
  const _Sample(this.bytes, this.at);
  final int bytes;
  final DateTime at;
}

class _TransferRateLineState extends State<TransferRateLine> {
  static const _window = Duration(seconds: 3);
  final _samples = <_Sample>[];

  void _record(int bytes) {
    final now = DateTime.now();
    // Reset on a backwards jump (retry from zero).
    if (_samples.isNotEmpty && bytes < _samples.last.bytes) _samples.clear();
    _samples.add(_Sample(bytes, now));
    // Drop samples older than the window, but keep at least two so we can
    // still span a rate baseline.
    while (_samples.length > 2 &&
        now.difference(_samples[1].at) >= _window) {
      _samples.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    _record(widget.transfer.bytesTransferred);
    final theme = Theme.of(context);

    double? bps;
    if (_samples.length >= 2) {
      final first = _samples.first;
      final last = _samples.last;
      bps = rate.bytesPerSecond(
        earlierBytes: first.bytes,
        earlierAt: first.at,
        laterBytes: last.bytes,
        laterAt: last.at,
      );
    }
    final label = rate.rateEtaLabel(
      rate.formatRate(bps),
      rate.formatEta(rate.etaSeconds(
        totalBytes: widget.transfer.totalBytes,
        bytesTransferred: widget.transfer.bytesTransferred,
        bytesPerSecond: bps,
      )),
    );
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        label,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }
}
