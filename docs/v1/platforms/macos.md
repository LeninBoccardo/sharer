# macOS — build, run, validate

Slice 5.x.5 phase 2 wired the native scaffold metadata so the existing
LAN feature set works on a Mac. Tray UX, NSSharingService extension,
code signing, and notarization are out of scope for this round.

## Build

```sh
flutter pub get
flutter build macos --release
# Output: build/macos/Build/Products/Release/sharer.app
```

For development:

```sh
flutter run -d macos
```

## Runtime requirements

- macOS 11 or later (the Flutter macOS engine's floor).
- Both devices on the same Wi-Fi / Ethernet broadcast domain (Sharer is
  LAN-only in v1).

## What this slice covered

- [`macos/Runner/Info.plist`](../../../macos/Runner/Info.plist) — added
  `NSBonjourServices = ["_sharer._tcp"]` and
  `NSLocalNetworkUsageDescription`. Apple gates mDNS browse on these
  two keys since macOS 13; without them, Bonsoir's `NSNetServiceBrowser`
  silently returns no results.
- [`macos/Runner/DebugProfile.entitlements`](../../../macos/Runner/DebugProfile.entitlements)
  and [`Release.entitlements`](../../../macos/Runner/Release.entitlements)
  — both declare `network.server` + `network.client`. Sharer is both
  (peers POST to us; we POST to peers).
- [`test/platform/macos_config_test.dart`](../../../test/platform/macos_config_test.dart)
  parses these XML files and asserts the load-bearing keys are present.
  Catches typos / accidentally dropped entries on every CI run.

## Manual validation checklist (when Mac hardware is available)

The CI build matrix verifies "compiles cleanly". Real-device validation
must verify "actually works":

1. **First launch** — `open build/macos/Build/Products/Release/sharer.app`.
   Look in console / Console.app for the **boot canary** the existing
   `lib/main.dart` logs:
   ```
   [sharer.crypto] AES-GCM backend: FlutterAesGcm   ← good (CommonCrypto)
   ```
   If it shows `_DartAesGcm`, native AES isn't loading on Mac. File an
   upstream issue against `cryptography_flutter_plus` and document the
   Mac path-B (method-channel bridge to CommonCrypto). Reference
   [reference_cryptography_flutter.md](../../../docs/v1/security.md)
   for the trap that bit us in slice 5.3.2.
2. **Local-network permission** — macOS will prompt with the copy from
   `NSLocalNetworkUsageDescription`. Grant it. If no prompt fires, the
   Info.plist key is wrong (the static test should have caught this,
   but an invisible whitespace difference could slip through).
3. **Pair with Windows / Android** — `Devices → Pair`. Scan the QR
   code on the other device, confirm the 6-digit fingerprint on both
   sides. Look for `[paired] paired device added: id=…` in logs.
4. **Send a small file** — pick the paired peer, drop a small file
   into the app. Verify it lands on the receiver. Log line on the
   sender: `[sharer.transport.client] POST done bytesSent=…`.
5. **Send a 100 MB file** — re-baseline throughput. Expect
   ~25–40 MB/s on Wi-Fi 6, similar to Windows. If it tanks at
   ~5 MB/s, the boot canary lied (or BackgroundAesGcm is in use for
   small chunks).
6. **Receive a file** — start the transfer from the other side. Verify
   it lands in `~/Downloads/` (Mac's standard Downloads folder via
   `path_provider.getDownloadsDirectory()`).
7. **Restart the app** — paired devices should still be there. Tests
   `flutter_secure_storage` is correctly using Keychain on Mac (which
   it does by default with no setup).

## Known limitations (alpha)

- **Unsigned binary**: the .app from the build pipeline is unsigned.
  First launch will show "unidentified developer" — right-click → Open
  to bypass. Proper code signing requires an Apple Developer ID; out
  of scope for v1.
- **No tray UX**: the Windows close-to-tray pattern doesn't extend
  here yet. Closing the window quits the app. `tray_manager` claims
  Mac support; wiring it is a follow-up.
- **No share-sheet**: NSSharingService extension is a separate native
  target. Skipped for v1. Use the in-app file picker.

## CI

The [`.github/workflows/build-matrix.yml`](../../../.github/workflows/build-matrix.yml)
runs `flutter build macos --debug --no-pub` on every push to `main`
and on pull requests. Catches dependency resolution + linker errors
without needing local Mac hardware. Does NOT catch runtime failures
(the validation checklist above is the only way).

## Reference

- [Apple — Configuring Bonjour for App Sandbox](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices)
- [Apple — Local Network Privacy FAQ](https://developer.apple.com/forums/thread/663858)
