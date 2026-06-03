import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/network_info.dart';

/// Trusts [network] — but for a no-SSID Wi-Fi (#17) gates the action behind a
/// one-time confirmation. With no readable name the trust fingerprint is just
/// `|subnet`, so the network can only be recognised by its /24 IP range, which
/// a different Wi-Fi handing out the same range would match identically.
/// Named Wi-Fi / Ethernet trust directly (one tap, unchanged).
///
/// Shared by the quiet-mode banner and the diagnostics current-network card so
/// the confirmation can never be bypassed via one of the two trust entry
/// points. Returns true when the network was actually trusted.
Future<bool> trustNetworkWithConfirm(
  BuildContext context,
  WidgetRef ref,
  NetworkInfo network,
) async {
  if (network.isUnnamedWifi) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_outlined),
        title: const Text('Trust this network?'),
        content: Text(
          "Sharer can't read this Wi-Fi's name, so it can only recognise it "
          'by its IP range (${network.subnet ?? 'unknown'}). A different '
          'Wi-Fi on the same range would look the same to Sharer.\n\n'
          'Enable the Wi-Fi name first for a stronger match.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Trust anyway'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
  }
  await ref.read(networkWatcherProvider).trust(network);
  return true;
}
