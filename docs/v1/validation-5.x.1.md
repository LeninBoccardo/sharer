# Slice 5.x.1 batch validation

Covers commits **44454a8 → 9b5d0d8** (point releases that came out of
the [5.x batch validation](validation-5.x.md)). Run on Realme RMX2202
+ Lenin-PC, both on `Casa L&B` Wi-Fi (`192.168.68.0/24`).

Process is the same as the previous round: drop logs into
[../../logs/](../../logs/), tell Claude only the section numbers + a
pass/fail per row, Claude reads the logs automatically before
responding. Bugs found here become 5.x.1.1 / 5.x.1.2 / etc.

---

## 0. Build / install

1. `flutter clean && flutter pub get` — note: this batch added one
   dep (`cryptography_flutter`), so the gradle/cocoapods cache is
   genuinely stale. The clean is not optional.
2. Real-device install on **both** Realme + Lenin-PC. Existing pair
   from the prior round can stay.
3. Confirm `flutter analyze` is clean and `flutter test` reports **270
   passing**.

---

## 1. Patch 5.3.1 — Android public Downloads folder

The previous round saved files to
`/storage/emulated/0/Android/data/com.example.sharer/files/Download/Sharer/`
(app-private). They should now go to the user-visible
`Download/Sharer/` (visible in Files app + gallery).

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Lenin-PC → Realme: send a small image. On Realme, open the system **Files** app → Downloads. | A `Sharer` subfolder exists, the image is inside. Tap it — opens in the gallery. |
| 1.2 | Repeat with a PDF. | Same `Sharer` subfolder, the PDF tile shows up. Tapping opens the PDF reader. |
| 1.3 | On Realme, look at the transfer-done notification's **Open** action. Tap it. | The OS launches the file in its default handler. (`open_filex` reads the absolute path the new locator returns from MediaStore.) |
| 1.4 | Send the same filename twice in a row (e.g. two `IMG_0001.jpg`). | MediaStore renames automatically — second copy lands as `IMG_0001 (1).jpg` (or similar) without overwriting the first. The receiver log shows the unique-name resolution at the staging layer too. |
| 1.5 | adb shell run-as com.example.sharer ls cache/sharer-staging — directly after a successful transfer. | The staging directory exists but is empty. The publish step deletes the staged file once MediaStore has it. (If a transfer failed mid-stream the staging file *can* remain; document if you see one.) |
| 1.6 | (Optional, only if you have an Android 9 / API 28 device handy) repeat 1.1 — would use the legacy `Environment.DIRECTORY_DOWNLOADS` path. | File ends up in the same Downloads/Sharer/ folder visible in Files. Realme RMX2202 is API 30+, so this row is skipped on the primary test device. |

**Pass criteria**: Realme's user-visible Downloads/Sharer/ now
contains every received file; staging directory in cache stays clean
after a successful transfer.

---

## 2. Patch 5.3.2 — native AES-GCM throughput

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Send a 100 MB file Lenin-PC → Realme over Wi-Fi. Note wall-clock time. | Should finish in ~5–10 seconds rather than the ~minute the previous round took. (LAN throughput is the real cap; pure-Dart AES-GCM was the old bottleneck and native AES-GCM removes it.) |
| 2.2 | Send a 500 MB file Realme → Lenin-PC. | Streams continuously, RAM stays bounded on Realme (32 KB chunks; check Android Studio's RAM monitor stays flat). |
| 2.3 | Eyeball the transfer-active toast progress on Lenin-PC during 2.2. | Updates roughly every ~256 KB (existing throttle); should be visibly smooth, not chunky. |
| 2.4 | Confirm `flutter analyze` + `flutter test` still pass after the dep was added. | Clean. (No dart-side test cases for the native plugin — flutter_test runs the pure-Dart fallback path.) |

**Pass criteria**: 100 MB file finishes within an order of magnitude
of LAN line-rate (~10s on a 100 Mbps Wi-Fi), no OOM on multi-100MB
files. If 2.1 still takes minutes, the native plugin didn't load on
the platform — flag for follow-up.

---

## 3. Patch 5.2.4.1 — peer-unpaired body tap + default body-tap routing

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Pair both devices. On Realme, tap trash on Lenin-PC in Devices. Lenin-PC should get a "Realme RMX2202 unpaired" toast. **On Lenin-PC, click the body of that toast.** | Sharer window comes forward. (Previously: nothing — the toast had no payload, the router had nothing to route on.) |
| 3.2 | Re-pair, then on Lenin-PC tap trash on Realme. **On Realme, tap the body of the "Lenin-PC unpaired" notification.** | Sharer activity comes forward on Realme. (Same as 3.1, mirrored.) |
| 3.3 | While Realme has any other notification visible (transfer-done, pair-invite, peer-unpaired), tap the body. | Always opens the app. New rule: every body tap brings the app forward unless we have a specific behavior (open file for transfer-done; show fingerprint for pair-invite). |
| 3.4 | A genuine action button you don't recognise — there isn't one in v1, so skip. | (No-op verification — confirmed by unit tests.) |

**Pass criteria**: every notification's body tap brings the app
forward; specific routes (Open / View / Decline) still work as
before.

---

## 4. Patch 5.2.4.2 — silent Decline when app is killed

This is the one that needed real plumbing. Test scenarios cover
"app foregrounded", "app backgrounded but isolate alive", and "app
fully killed."

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Realme **foregrounded**. From Lenin-PC, send a pair invite. On Realme, swipe down the notification shade and tap **Decline**. | Lenin-PC log: `recordRemoteFinalize: peer declined`. The fingerprint modal on Lenin-PC closes / shows declined. Realme's Sharer does NOT come to the foreground. |
| 4.2 | Realme **backgrounded but recently used** (Sharer was open in last few minutes; Android may have its isolate cached). From Lenin-PC, pair invite → Realme tap Decline. | Same outcome as 4.1. |
| 4.3 | **The hard case — Realme fully killed.** Force-stop Sharer on Realme via Settings → Apps → Sharer → Force stop. From Lenin-PC, send a pair invite. Realme gets the notification. **Tap Decline on Realme without opening the app.** | Lenin-PC log: `recordRemoteFinalize: peer declined`. Modal closes. Realme's Sharer process never appears in recents. (The BG isolate handler reads the pre-signed payload from the InFlightInviteStore + posts decline. No UI flash.) |
| 4.4 | Same as 4.3 but immediately after Realme tapped Decline, force-launch Sharer manually. | The pair shouldn't be present in either side's Devices list. The InFlightInviteStore should be empty (the BG handler removes the entry on a successful POST). |
| 4.5 | (Negative test) On Realme, with Sharer killed, swipe-dismiss a pair-invite notification *without* tapping Decline. | The invite expires naturally after 5 min on Lenin-PC's side (existing slice 5.1.2 sweep). The InFlightInviteStore entry is purged by the next `_purgeExpired` tick on Realme when the user next opens the app. |

**Pass criteria**: 4.1 and 4.2 work as before, 4.3 newly works.
Specifically: Lenin-PC sees the decline POST land. Realme does not
foreground.

---

## 5. (Carry-over from previous round) — slice 5.4.3.c reactive 401

This was un-run last round; pull it forward.

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Wipe Realme: Settings → Apps → Sharer → Storage → Clear data, then reinstall. (Regenerates Realme's Ed25519 identity AND wipes its PairedDevices.) On Lenin-PC, do **not** clean — the legacy entry for Realme is now stale. From Lenin-PC, pick the (still-listed-on-PC) Realme in the peer list and try to send a file. | Lenin-PC log: `Send failed id=... Upload failed: 401`. Reactive forget fires: `recordReactive401 ... (Realme)`. The stale Realme entry is removed. Lenin-PC user sees a "Realme RMX2202 unpaired" toast (which now correctly opens the app on body tap, per §3). |
| 5.2 | After 5.1, refresh Lenin-PC's Devices screen. | Realme is gone. The transfer entry shows `failed`. |
| 5.3 | Re-pair both devices fresh. | Pair flow works end-to-end with the regenerated Realme identity (deviceId churn is expected — see project_test_devices memory). |

**Pass criteria**: stale pair removed automatically after a single
failed send; toast surfaces; user can re-pair without manual cleanup.

---

## 6. (Carry-over from previous round) — slice 5.5 Android share-sheet

Also un-run last time.

| # | Action | Expected |
|---|--------|----------|
| 6.1 | On Realme, open Photos. Pick one image, tap Share. | **Sharer** appears in the Android share-sheet target list. |
| 6.2 | Tap Sharer with the app **not running** (force-stop first). | Sharer cold-starts, the home screen renders with a `Sharing <filename>` banner at the top. |
| 6.3 | Tap **Lenin-PC** in the peer list while the share banner is up. | The image transfers to Lenin-PC. Banner clears, snackbar `Sending <name> → Lenin-PC…` appears. Saved file on PC matches the original byte-for-byte. |
| 6.4 | Repeat 6.1 with Sharer already foregrounded. | Banner appears in-place (no cold start). Same transfer flow. |
| 6.5 | Pick **multiple** images, share, tap Sharer. | Banner says `Sharing N files`. Tapping Lenin-PC sends all of them; snackbar reflects `N files`. |
| 6.6 | Open Sharer, share a file in (banner appears), tap the **X** on the banner. | Banner clears without sending. Cached temp files in `cacheDir/share_*` are deleted. |

**Pass criteria**: Sharer appears in the system share sheet;
ACTION_SEND + ACTION_SEND_MULTIPLE both flow through to a paired peer.

---

## Reporting back

Same workflow:

1. Section number(s) you ran (e.g. `1, 2, 4` or `all`).
2. Pass/fail per row.
3. The few log lines that look most relevant.

Drop logs into [../../logs/](../../logs/) — Claude reads them
automatically.

Bugs found in this round become 5.3.1.1 / 5.3.2.1 / 5.2.4.1.1 /
5.2.4.2.1 / etc. Tracked one-at-a-time the small-commit way.

---

## Out of scope for this batch (still pending)

- Windows Share contract registration (MSIX packaging) — **5.5.x**.
- Internet relay / cross-network paired peers — slice 6.x; design
  notes are in [../v2/overview.md](../v2/overview.md).
- iOS / macOS / Linux ports — v2.
- Stale-pair "yellow dot" badge — folded into reactive-401 + proactive
  forget; revisit only if the implicit removal feels too eager.
