import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Slice 5.2.2: one-shot prompt that appears on the home screen the
/// first time the user has at least one paired device AND Sharer is
/// not whitelisted from battery optimization. Dismissable and
/// remembered — once tapped (either action), it never shows again on
/// this install.
///
/// **Why this exists:** the foreground service alone isn't enough on
/// the OEMs Lenin tests on (Realme/Oppo). Their custom kill manager
/// terminates backgrounded apps even with a FG notification active
/// unless the user has explicitly added them to the whitelist.
class BatteryOptimizationBanner extends ConsumerStatefulWidget {
  const BatteryOptimizationBanner({super.key});

  @override
  ConsumerState<BatteryOptimizationBanner> createState() =>
      _BatteryOptimizationBannerState();
}

class _BatteryOptimizationBannerState
    extends ConsumerState<BatteryOptimizationBanner> {
  /// Persisted across launches; once true, the banner never shows
  /// again. The user can re-trigger via a future settings entry if
  /// they change their mind.
  static const _prefKey = 'battery_opt_prompt_dismissed';

  bool _checked = false;
  bool _shouldShow = false;

  @override
  void initState() {
    super.initState();
    // Defer the platform check off the build path so we don't race
    // first-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(_prefKey) ?? false) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    final gateway = ref.read(foregroundServiceGatewayProvider);
    final ignoring = await gateway.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _checked = true;
      _shouldShow = !ignoring;
    });
  }

  Future<void> _dismiss() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_prefKey, true);
    if (mounted) setState(() => _shouldShow = false);
  }

  Future<void> _openSettings() async {
    final gateway = ref.read(foregroundServiceGatewayProvider);
    await gateway.requestIgnoreBatteryOptimizations();
    // Whether the user actually toggles the OS setting or backs out,
    // we treat the prompt as resolved — re-prompting on every cold
    // boot would be obnoxious. The banner can be brought back via a
    // future Settings entry if the user changes their mind.
    await _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked || !_shouldShow) return const SizedBox.shrink();
    final paired = ref.watch(pairedDeviceIdsProvider);
    if (paired.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
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
              Icon(Icons.battery_saver,
                  color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Allow Sharer to receive in the background',
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
            'Some Android devices kill backgrounded apps even when '
            'they\'re actively listening. Whitelisting Sharer keeps '
            'incoming files reliable.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _dismiss,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                ),
                child: const Text('Not now'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: _openSettings,
                child: const Text('Open settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
