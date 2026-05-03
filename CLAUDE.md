# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This is a freshly-scaffolded Flutter project. [lib/main.dart](lib/main.dart) and [test/widget_test.dart](test/widget_test.dart) still contain the default counter-app boilerplate from `flutter create` — they are placeholders, not the real app, and should be replaced as the LAN-sharing app is built out.

The product spec is split across two locations:

- [APP_INITIAL_DOCS.md](APP_INITIAL_DOCS.md) — original architecture brainstorm. Read for context, but treat anything in `docs/` as the **authoritative override**.
- [docs/](docs/) — versioned, living spec. Per-version folder (`docs/v1/`, `docs/v2/`, …). When a `docs/vN/` doc contradicts `APP_INITIAL_DOCS.md`, the `docs/` version wins.

Always read the latest `docs/vN/` before making non-trivial architectural changes.

## Commands

```sh
flutter pub get              # install dependencies
flutter run                  # run on the default connected device (auto-selects)
flutter run -d windows       # explicit target — also: chrome, android, linux, macos
flutter analyze              # static analysis (uses analysis_options.yaml + flutter_lints)
flutter test                 # run all tests
flutter test test/widget_test.dart           # run a single test file
flutter test --plain-name "test description" # run tests by name
flutter build <target>       # apk, appbundle, windows, web, ios, macos, linux
```

Targets enabled in this project: `android`, `ios`, `linux`, `macos`, `web`, `windows`.

Dart SDK constraint: `^3.11.5` (see [pubspec.yaml](pubspec.yaml)).

## Non-negotiable product principles

These are the load-bearing constraints the app is judged against. Any design that violates one is wrong, even if technically clean.

1. **Speed is the #1 feature.** The complete user flow — *open share sheet → pick peer → file is sent* — must feel instant. Cold init, peer discovery, and connection setup all count against this budget. Optimize aggressively: cache last-known peers, fire optimistic connects against cached IPs in parallel with fresh discovery, prewarm the HTTP server, etc. If a "nice" abstraction adds even ~100 ms to the share path, drop the abstraction.

2. **OS-level share-sheet integration is required, not optional.** The app must appear in the system share menu (Android `ACTION_SEND` intent filter, Windows Share contract, etc.) so the user shares *into* sharer, not *opens* sharer to share. Showing discovered peers directly in the share sheet (Android Direct Share / iOS share targets) is the ideal but acceptable to defer if it adds complexity — the app entry itself is the must-have.

3. **Background cost must be near-zero.** No always-on heavy processes. The mDNS announcer should *not* run constantly; prefer event-driven announcement (announce on share UI open / app foreground) plus a cheap passive listener. On Android use a foreground service only when actively transferring.

4. **Minimum-clicks UI.** Default flow target: ≤ 2 taps from share sheet to "transfer started." Settings and configuration are secondary screens, never on the share path.

5. **Polished, modern UI within the perf budget.** Shadows, soft curves, gradients, and animations are welcome — but any animation that delays the share path or drops frames on mid-range Android is wrong. The app should not look like a hobby script.

6. **Any file, any size.** No type filtering, no size cap. Use chunked/streamed transfer; never load full files into memory.

## Architecture (planned — not yet implemented)

The app is a **P2P mesh** — every device runs both an HTTP server and an HTTP client simultaneously. There is no central coordinator. Five subsystems run concurrently on each device:

1. **HTTP server** (port 8080) — receives files from peers. Implemented with the `shelf` package. Streams uploads directly to disk.
2. **HTTP client** — sends files to any discovered peer. Streams from disk; never buffers a full file in RAM.
3. **mDNS announcer** — broadcasts presence on `224.0.0.251` using a custom service type (e.g. `_sharer._tcp`) so discovery is filtered to actual sharer peers. Event-driven, not always-on. Uses `multicast_dns`.
4. **mDNS listener** — discovers peers and maintains the peer list (peers expire on TTL). Listens passively even when announcer is idle.
5. **Network watcher** — checks SSID + subnet against the set of trusted networks the user has approved. On an unrecognized network the watcher enters **quiet mode**: stop mDNS announcer, do **not** stop the HTTP server. Paired peers (cert-pinned, HMAC-signed) can still reach this device via cached IPs on any network. See **Security model** below.

The trust boundary is the **pairing**, not the network. The watcher exists to keep the device from broadcasting its presence on untrusted Wi-Fi, not to block authenticated peers.

### Transfer protocol

REST over HTTP (HTTPS once self-signed certs are added):

- `POST /upload` — push a file to a peer (chunked / streamed)
- `GET /files/:id` — pull a file from a peer (chunked / streamed)

Every request carries an `X-Sharer-Sig` HMAC header — see security model.

### Default download location

System **Downloads** folder. Not configurable in v1. A "change download folder" setting is explicitly out of scope until v1 ships.

## Security model (refined)

SSID + subnet check alone is too weak — SSID is trivially spoofable. The refined model layers cheap checks on top of strong ones:

1. **Discovery filter (cheap):** mDNS service type `_sharer._tcp`. Only sharer instances appear in peer lists. Prevents accidental discovery, not a security boundary on its own.
2. **Pairing & shared secret (the real boundary):** devices pair once via QR code (or short numeric code as fallback). Pairing exchanges a 256-bit pre-shared key (PSK) stored in secure storage on each side. Only paired peers can complete a transfer.
3. **Per-request signature:** every HTTP request includes an HMAC-SHA256 signature over `(method | path | timestamp | body-hash)` using the PSK. Replay-protected by the timestamp window (~30 s).
4. **TLS with self-signed cert pinning:** each device generates a self-signed cert at first run; the cert fingerprint is exchanged during pairing and pinned. Defeats LAN MITM.
5. **Network watcher → quiet-mode toggle (not a kill-switch):** SSID + subnet still monitored. On an unrecognized network, the watcher **stops the mDNS announcer only** so the device doesn't broadcast its presence. The HTTP server keeps running; paired peers can still reach it via cached IPs (HMAC + cert pin still gate access). The user sees a banner explaining quiet mode and can promote the network to "trusted" to re-enable announcements.

Implementation order: get (1) + (5) working first (cheap, lets MVP transfers happen), then (2)+(3) before any cross-device pairing, (4) before v1 ships.

## Code conventions

The codebase aims for a long-life, easily-extensible foundation. Apply these as the structure is built — not as a retrofit later.

- **Clean Architecture layering**: `domain` (entities, use-cases, abstract repository interfaces — pure Dart, no Flutter), `data` (concrete implementations: HTTP server/client, mDNS, secure storage), `presentation` (Flutter widgets, state management). Dependencies point inward; `domain` depends on nothing in `data` or `presentation`.
- **SOLID**, especially the D: every cross-layer dependency is an interface in `domain`, injected at composition root.
- **High decoupling**: subsystems (server, client, announcer, listener, watcher) communicate via streams / event bus, not direct method calls. Swapping mDNS for another discovery mechanism should touch one file.
- **Design patterns where they pay off**: Repository for storage abstractions, Strategy for transfer protocols, Observer (Stream) for peer-list updates. Don't pattern-cargo-cult — only when there's a second implementation in sight.
- **Testing**: unit tests for `domain` use-cases (no mocks of Flutter), integration tests for `data` adapters against real local sockets where feasible, widget tests for critical UI flows (share path).
- **No premature abstraction**: until there are two callers, write the concrete code. The above structure exists *because* there are at least two real implementations on the horizon (multiple platforms, eventual transport swap).

## Platform notes

- **Android:** reading SSID on Android 8+ requires `ACCESS_FINE_LOCATION`. The app also needs `INTERNET`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` (for mDNS), and `FOREGROUND_SERVICE` (for active-transfer service). Manifest goes in `android/app/src/main/AndroidManifest.xml`. The share-sheet intent filter (`ACTION_SEND` / `ACTION_SEND_MULTIPLE` with `mimeType="*/*"`) is what makes the app appear in the system share menu.
- **Windows:** OS firewall prompts on first run to allow the HTTP server. Share contract registration is what makes the app appear in the Windows Share UI.
- **iOS / macOS:** share-sheet integration requires a separate native Share Extension target — heavier work, may slip to a later version.

## Reference implementation

[LocalSend](https://github.com/localsend/localsend) follows the same P2P architecture and is the canonical reference when a design question comes up. Its pairing flow, mDNS service type usage, and Android share-sheet integration are all worth studying directly.
