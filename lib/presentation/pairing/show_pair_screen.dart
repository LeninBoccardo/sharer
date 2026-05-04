import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/providers.dart';
import '../../data/network/local_addresses.dart';
import '../../data/security/pairing_codec.dart';
import '../../domain/entities/paired_device.dart';
import '../../domain/entities/pairing_offer.dart';

/// Initiator side of pairing. Mints a fresh offer the moment the screen
/// opens and renders it as a QR code (primary) plus a 6-digit numeric
/// code (informational fallback). Listens on
/// [PairingService.completions] and dismisses with a snackbar once the
/// responder has POSTed a valid completion.
class ShowPairScreen extends ConsumerStatefulWidget {
  const ShowPairScreen({super.key});

  @override
  ConsumerState<ShowPairScreen> createState() => _ShowPairState();
}

class _ShowPairState extends ConsumerState<ShowPairScreen> {
  PairingOffer? _offer;
  String? _error;
  StreamSubscription<PairedDevice>? _completionSub;
  Timer? _countdownTicker;
  Duration _timeLeft = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final port = ref.read(httpFileServerProvider).boundPort;
    if (port == null) {
      setState(() => _error =
          'Trust this network first to show a pairing code. Pairing has '
          'to happen on a network you control.');
      return;
    }

    // Enumerate every local IPv4 — the responder may not be reachable on
    // our default-route interface (PCs typically have a Hyper-V/Ethernet
    // adapter that's invisible to phones on the home Wi-Fi).
    final ips = await localIpv4Addresses();
    if (ips.isEmpty) {
      if (!mounted) return;
      setState(() => _error =
          'No local network address available. Connect to a network and '
          'try again.');
      return;
    }
    final endpoints = [for (final ip in ips) '$ip:$port'];

    final pairing = ref.read(pairingServiceProvider);
    final offer = await pairing.createOffer(endpoints: endpoints);

    _completionSub = pairing.completions.listen((paired) {
      if (paired.deviceId == offer.initiatorId) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paired with ${paired.displayName}')),
      );
      Navigator.of(context).maybePop();
    });

    if (!mounted) return;
    setState(() {
      _offer = offer;
      _timeLeft = offer.expiresAt.difference(DateTime.now());
    });
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTicker?.cancel();
    _countdownTicker =
        Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    final offer = _offer;
    if (offer == null) return;
    final remaining = offer.expiresAt.difference(DateTime.now());
    if (!mounted) return;
    if (remaining.isNegative) {
      _countdownTicker?.cancel();
      _countdownTicker = null;
      setState(() {
        _timeLeft = Duration.zero;
        _error = 'This code has expired. Go back and tap Show code again.';
        _offer = null;
      });
      ref.read(pairingServiceProvider).cancelOffer(offer.offerId);
      return;
    }
    setState(() => _timeLeft = remaining);
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    final offer = _offer;
    if (offer != null) {
      ref.read(pairingServiceProvider).cancelOffer(offer.offerId);
    }
    _completionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Show pairing code')),
      body: SafeArea(child: _body(context, theme)),
    );
  }

  Widget _body(BuildContext context, ThemeData theme) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline,
                  size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 16),
              Text(error,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }

    final offer = _offer;
    if (offer == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final encoded = encodePairingOffer(offer);
    final secondsLeft = _timeLeft.inSeconds.clamp(0, 99);
    final primaryEndpoint = offer.endpoints.first;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Center(
            child: Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: QrImageView(
                  data: encoded,
                  size: 280,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text('On the other device, tap "Scan code" and point its '
              'camera at this screen.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text('Numeric code',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(height: 4),
                Text(
                  offer.numericCode,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                Text('$primaryEndpoint  ·  expires in ${secondsLeft}s',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
