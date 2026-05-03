# v1 — UX

## Guiding principles

- **Speed beats polish, polish beats features.** Animations stay only if they don't delay the share path. Features stay out unless they're in the v1 scope list.
- **The share sheet is the primary entry point.** Most users will never open the app standalone — they'll share *into* it from another app.
- **Click budget for the share path: ≤ 2 taps** from share sheet to "transfer started." One tap to pick the peer is the floor; that's the target.

## Primary flow — sending a file

```text
Source app: tap share icon → system share sheet
  ↓
Tap "Sharer" (or, ideally, tap a discovered peer rendered directly in the share sheet via Direct Share)
  ↓
Sharer share screen opens, peer list already populated from cache + listener
  ↓
Tap a peer  ← this is the only required tap inside sharer
  ↓
Transfer screen: progress bar, peer name, file name, cancel button
  ↓
On complete: brief success animation, auto-dismiss after ~1 s (or stays if user is interacting)
```

Total taps inside sharer in the happy path: **1**.

## Primary flow — receiving a file

```text
Other device starts sending → push-style notification on this device:
   "Phone is sending IMG_1234.jpg (4.2 MB) — Accept / Reject"
  ↓
Tap Accept
  ↓
Transfer screen with progress
  ↓
On complete: notification "Saved to Downloads" with "Open" action
```

Auto-accept from paired devices is offered as a per-peer setting — defaulted off in v1 (always prompt), with a clear toggle in the peer's detail screen. (Open question — see [open-questions.md](open-questions.md).)

## Standalone app entry

Opening the app icon directly (not via share sheet) lands on a home screen with three sections:

1. **Send** — file picker, then peer picker.
2. **Receive** — passive screen showing "Ready, discoverable as `{DeviceName}`" and recent transfers.
3. **Devices** — paired device list, "+ Add device" pairing flow.

Settings is a quiet icon in the top-right; not on the share path.

## Visual style

Modern but restrained. The intent is "looks like Material You / fluent app from a respectable studio," not "fintech startup pitch deck."

- Soft elevation shadows, generous corner radius (16–20 dp on cards, 12 dp on buttons).
- Subtle gradient backgrounds on the share screen and pairing screen — not on every screen.
- One brand accent color (TBD), used for primary CTA and peer-online dot.
- Typography: system default. No custom font in v1.
- Animations: 150–250 ms ease-out. Nothing slower. Hero animations on peer-tap → transfer screen are good if they don't delay the actual upload (which fires immediately, animation is decorative).

## Error states

- "On unrecognized network — discoverability off" — non-blocking banner on the home/share screens. **Sharing with already-paired peers still works** (their cached IPs are tried automatically). The banner offers a "Trust this network" CTA that adds the SSID + subnet to the trusted list and resumes mDNS announcements. Pairing *new* devices is disabled in this state — pairing requires a trusted network.
- "Peer not reachable" — inline on transfer screen, "retry" CTA, transfer state preserved for resume (resume itself is post-v1; v1 just retries from zero).
- "No peers found" — empty state on share screen, with explanatory text and "scan for new peers" button.
- Pairing failures (expired code, mismatched fingerprint) — surface clearly during pairing, never during transfer.

## What the v1 UI does NOT include

- Transfer history beyond the current session.
- Bulk multi-peer send.
- Folder/multi-file selection beyond what the OS share sheet hands us.
- Theming / dark-mode toggle (just follow the system theme).
- Settings beyond: device name, view paired devices, view trusted network.
