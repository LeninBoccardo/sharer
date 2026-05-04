import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/providers.dart';
import '../../data/security/pairing_client.dart';
import '../../data/security/pairing_codec.dart';
import '../../domain/entities/pairing_offer.dart';

/// Responder side of pairing. On phones it opens the camera and watches
/// for a Sharer pairing QR. On desktops without a camera it shows a
/// short explainer pointing the user back to the other device.
class ScanPairScreen extends ConsumerStatefulWidget {
  const ScanPairScreen({super.key});

  @override
  ConsumerState<ScanPairScreen> createState() => _ScanPairState();
}

class _ScanPairState extends ConsumerState<ScanPairScreen> {
  bool _processing = false;
  String? _status;

  bool get _supportsScanner => Platform.isAndroid || Platform.isIOS;

  Future<void> _consume(String raw) async {
    if (_processing) return;
    final offer = decodePairingOffer(raw);
    if (offer == null) {
      setState(() => _status = 'Not a Sharer pairing code.');
      return;
    }
    if (offer.isExpired(DateTime.now())) {
      setState(() => _status = 'This code has expired. Generate a new one.');
      return;
    }
    setState(() {
      _processing = true;
      _status = 'Pairing with ${offer.initiatorName}…';
    });
    await _completePairing(offer);
  }

  Future<void> _completePairing(PairingOffer offer) async {
    final identity = await ref.read(deviceIdentityRepoProvider).get();
    final client = ref.read(pairingClientProvider);
    final result =
        await client.postCompletion(offer: offer, responder: identity);

    if (!mounted) return;

    switch (result) {
      case PairingPostResult.ok:
        await ref.read(pairingServiceProvider).acceptOffer(offer);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Paired with ${offer.initiatorName}')),
        );
        Navigator.of(context).maybePop();
      case PairingPostResult.rejected:
        setState(() {
          _processing = false;
          _status = 'The other device rejected the pairing. The code may '
              'have expired or already been used.';
        });
      case PairingPostResult.networkError:
        setState(() {
          _processing = false;
          _status = 'Could not reach ${offer.endpoint}. Make sure both '
              'devices are on the same Wi-Fi.';
        });
      case PairingPostResult.malformedEndpoint:
        setState(() {
          _processing = false;
          _status = 'Malformed pairing endpoint in the QR code.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: SafeArea(child: _body(theme)),
    );
  }

  Widget _body(ThemeData theme) {
    if (!_supportsScanner) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined,
                  size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              Text('Camera scanning is only available on phones.',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Open Devices on the other phone, tap Scan code, and point '
                'its camera at this device after tapping Show code here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        MobileScanner(
          fit: BoxFit.cover,
          onDetect: (capture) {
            for (final code in capture.barcodes) {
              final value = code.rawValue;
              if (value != null && value.isNotEmpty) {
                _consume(value);
                break;
              }
            }
          },
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _status == null
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey(_status),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        if (_processing)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          ),
                        if (_processing) const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _status!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
