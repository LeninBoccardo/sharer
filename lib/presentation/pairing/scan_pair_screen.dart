import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/providers.dart';
import '../../data/security/pairing_client.dart';
import '../../data/security/pairing_codec.dart';
import '../../domain/entities/pairing_offer.dart';

/// Responder side of pairing. mobile_scanner v5+ supports Android, iOS,
/// macOS, and Windows webcams; on platforms without a camera (Linux
/// builds, headless desktops) the package itself surfaces an empty
/// preview rather than throwing — we let it through.
class ScanPairScreen extends ConsumerStatefulWidget {
  const ScanPairScreen({super.key});

  @override
  ConsumerState<ScanPairScreen> createState() => _ScanPairState();
}

class _ScanPairState extends ConsumerState<ScanPairScreen> {
  bool _processing = false;
  String? _status;

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
          _status = 'Could not reach ${offer.initiatorName} '
              '(tried ${offer.endpoints.join(", ")}). Make sure both '
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
    return Stack(
      children: [
        MobileScanner(
          fit: BoxFit.cover,
          errorBuilder: (context, error, _) =>
              _CameraUnavailable(error: error, theme: theme),
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

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.error, required this.theme});

  final MobileScannerException error;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('Camera not available on this device.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              _hint(error.errorCode),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  static String _hint(MobileScannerErrorCode code) {
    switch (code) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Camera permission was denied. Grant it in system settings, '
            'or pair from the other side: tap Show code there and scan it '
            'from this device once permission is restored.';
      case MobileScannerErrorCode.unsupported:
        return 'This device does not have a camera available. Open Devices '
            'on a phone, tap Scan code, and point it at this screen after '
            'tapping Show code here.';
      default:
        return 'The camera could not be opened. Try Show code from this '
            'device and scan it on the other one instead.';
    }
  }
}
