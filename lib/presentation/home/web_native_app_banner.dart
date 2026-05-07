import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// URL of the landing page where users can download the native app.
/// Defaults to the GitHub Pages URL the `landing-deploy.yml` workflow
/// publishes to. Change this string if you host the landing page
/// elsewhere (Cloudflare Pages, Netlify, custom domain).
const String kSharerLandingPageUrl = 'https://leninboccardo.github.io/sharer/';

/// Slice 5.x.6: web-only banner that surfaces on the home screen,
/// inviting the user to download the native app. P2P file sharing
/// over LAN cannot work in a browser (no raw sockets, no mDNS, no
/// HTTP server bind), so the web build is a stepping stone toward
/// the WebRTC receive-in-browser feature for v2 — until that lands,
/// it's mostly an inert preview.
///
/// Renders an empty SizedBox on every native platform, so the same
/// home screen is byte-equivalent on Android / Windows / macOS / Linux.
class WebNativeAppBanner extends StatelessWidget {
  const WebNativeAppBanner({super.key});

  Future<void> _open() async {
    final uri = Uri.parse(kSharerLandingPageUrl);
    // mode: externalApplication asks the browser to handle navigation
    // however it normally does — typically a new tab. Falls back to
    // the default mode if the browser has overrides.
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_for_offline_outlined,
                  color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'You\'re using the web preview',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Browsers can\'t do peer-to-peer LAN file transfer (no '
            'sockets, no mDNS). Get the native app for full sharing '
            'between your devices.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.tonalIcon(
                onPressed: _open,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
