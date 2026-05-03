# v1 — Overview

Status: **in design** (no implementation yet — `lib/main.dart` still holds the `flutter create` boilerplate).

## What v1 ships

A single-purpose P2P LAN file-sharing app:

- Discover other sharer instances on the same Wi-Fi.
- Send any file (any size, any type) to a discovered peer.
- Receive incoming files into the system Downloads folder.
- Appear in the OS share sheet on Android and Windows so the app is invoked *from* other apps' share menus, not opened standalone.

## What v1 does NOT ship

Explicitly out of scope — defer to v2+:

- iOS / macOS share-extension targets (Flutter app may still run on those platforms; native share-sheet integration is the deferred part).
- Configurable download folder.
- Group transfers (one sender → many peers in one go).
- Transfer history / resume.
- Cloud fallback for off-LAN sharing.

## Success criteria

- **Speed**: cold-start share path (open share sheet → tap peer → upload begins) under ~2 s on a typical home Wi-Fi when the target peer is a known/cached device.
- **Battery**: zero measurable drain when the app is installed but idle in the background.
- **Reliability**: a 4 GB file transfer between phone and PC completes without OOM, without re-transferring, and reports clear progress.
- **Polish**: looks like a product, not a prototype. No janky animations, no unstyled material defaults.
- **Pairing is one-time, network-agnostic**: once two devices are paired (QR scan, ~10 s of one-time setup), they remain trusted forever. They can transfer files on any Wi-Fi they meet on — the pairing is the trust boundary, not the network. Re-pairing because of an SSID change is a bug.

## Target platforms for v1

- Android (primary mobile target; full share-sheet integration)
- Windows (primary desktop target; full Share contract integration)

iOS, macOS, Linux, Web: the Flutter app may compile and run on these, but native OS-share integration is **not** a v1 deliverable.

## See also

- [architecture.md](architecture.md) — subsystem design
- [security.md](security.md) — pairing, signatures, kill-switch
- [ux.md](ux.md) — flows and click-budgets
- [open-questions.md](open-questions.md) — unresolved design calls
