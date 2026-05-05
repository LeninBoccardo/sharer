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

In slice 5.2 the receiver is reachable even with the app closed (Android: foreground service; Windows: tray).

```text
Other device starts sending → notification on this device:
   "Realme is sending IMG_1234.jpg (4.2 MB)"  + progress bar that updates
  ↓
While transfer runs, the heads-up notification collapses into the shade with progress
  ↓
On complete: notification "Saved IMG_1234.jpg to Downloads" with "Open" action
```

Per OQ-2, transfers from paired peers are accepted automatically in v1 — there is no "Accept / Reject" prompt for paired devices. Per-peer trust posture is an open polish item; if a future version adds a "confirm before save" toggle, this notification gains the action buttons. The protocol-level accept happens when the request arrives; the user sees only the resulting "incoming" notification and can cancel mid-transfer from the Transfers section.

## Background presence

What's persistent and what isn't, per platform:

| Platform | Idle ambient indicator | Transfer-time notification | Notes |
| --- | --- | --- | --- |
| Android | One collapsed line in the notification shade (channel `service_idle`, `IMPORTANCE_MIN`) — only present while paired count > 0 | Heads-up + progress on `transfer_active` (`IMPORTANCE_LOW`); idle notification cancelled while transfer runs | OS forces *some* notification while the FG service runs. We minimise it; the user can long-press → channel settings → mute the channel entirely if they prefer (then it's invisible but still surfacing transfers). |
| Windows | Tray icon (overflowable) | Toast on start + completion | Closing the window hides to tray. Only Quit from the tray menu exits. |
| iOS | None (foreground-only per [OQ-9](open-questions.md)) | Foreground only | App must be open; documented limitation. |

The "no notification at all when idle" UX you might expect from a desktop chat app is achievable on Windows but not on Android. This is an OS rule, not a Sharer choice.

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

## Pairing UX (slices 4.3–4.6)

### Pair-first sheet (slice 4.4)

Tapping an unpaired peer in the home picker opens a modal sheet, not the file picker:

> **Pair with `Realme RMX2202` first**
> Devices need to pair once before sharing files. After pairing they can transfer freely on any network.
> **[Pair via QR]   [Cancel]**

"Pair via QR" pushes the Devices screen with the show-code/scan-code shortcuts. After pairing succeeds, the user taps the (now badged) peer again to start a send — we don't try to remember the picked file across the pairing flow.

### Fingerprint-confirm modal (slice 4.6)

Both sides of a LAN pair invite see the same modal:

> **Confirm pairing with `Lenin-PC`**
> Both screens should show the same number. If they don't, someone may be relaying.
> **`12 34 56`** (large, monospaced, tabular)
> **[Doesn't match]   [Matches]**

UX rules, all load-bearing:

1. **Modal-blocking.** No swipe-to-dismiss, no system-back, no tap-outside. Only the two buttons or an explicit Cancel exit it.
2. **No timeout = accept.** A 60-second timer expiring aborts pairing on both sides; it never advances to "Matches" silently.
3. **Both sides must confirm.** The protocol does not store the pair until both ends have tapped Matches. If A confirms and B aborts, A's modal shows "Other device cancelled" and rolls back.
4. **Process-death is explicit.** App killed mid-confirm wipes the in-flight pair and shows "Previous pairing was interrupted — re-pair?" on next launch, never auto-resumes.

### Stale-pair badge (slice 5.4)

The Devices list shows a small dot per pair:

- **Green** — last successful transfer or heartbeat within 24 h.
- **Yellow** — visible via mDNS but no successful transfer in 7+ days. "Try Send to confirm we're still paired."
- **Red** — last send attempt returned 401 (peer likely forgot us). Tapping the row offers "Forget them too?" to restore symmetry.

No broadcasts. The signal flows only one way: I tried to send → I was rejected → I conclude something's wrong → user decides. See [security.md §forget/rediscover](security.md).

## What the v1 UI does NOT include

- Transfer history beyond the current session.
- Bulk multi-peer send.
- Folder/multi-file selection beyond what the OS share sheet hands us.
- Theming / dark-mode toggle (just follow the system theme).
- Settings beyond: device name, view paired devices, view trusted network.
