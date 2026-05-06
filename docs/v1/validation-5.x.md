# Slice 5.x batch validation

Covers commits **c3b1ab1 → 3263998** (slices 5.2.4 + 5.3 + 5.4 + 5.5).
Run on Realme RMX2202 + Lenin-PC, both on `Casa L&B` Wi-Fi
(`192.168.68.0/24`). Treat any deviation from the expected outcome as a
candidate point-release (5.x.1, 5.x.2, …) and report with the matching
section number.

After every "validation round" you run, drop the logs into
[logs/](logs/) — Claude reads `logs/send-test-android-logs.txt` and
`logs/send-test-windows-logs.txt` automatically before responding.

---

## 0. Build / install

1. `flutter clean && flutter pub get` on a fresh checkout. (No new
   pubspec deps in this batch beyond what already shipped — no
   gradle/cocoapods churn expected.)
2. Real-device install on **both** Realme + Lenin-PC. Pair them once via
   QR or LAN-invite as a clean baseline. (You already have both paired
   from the slice 5.2.x rounds; that's fine — re-pair only if either
   side's identity has churned.)
3. Confirm `flutter analyze` is clean and `flutter test` reports **250
   passing**.

---

## 1. Slice 5.2.4 — notification routing (re-validation)

This was already partially validated end-of-last-session; re-run to
confirm nothing regressed under the 5.3 / 5.4 wire-format changes.

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Realme → Lenin-PC: send a small file. On Realme, while the toast is in flight, tap the body. | App comes forward; toast clears when the transfer completes. |
| 1.2 | Same flow, tap the **Open** action on the transfer-done toast (Realme). | OS opens the saved file with the default app. |
| 1.3 | Lenin-PC → Realme: send a file. On Lenin-PC, body-tap the Windows transfer-done toast. | App window comes forward; the toast disappears. |
| 1.4 | Lenin-PC → Realme: same, tap the **Open** action button on the Windows toast. | OS opens the saved file (no Action Center duplicate). |
| 1.5 | Lenin-PC → Realme: kill Realme, then send. From Realme's notification shade tap **View**. | App cold-starts and the fingerprint modal opens for the in-flight invite (or skips — depends on whether 5.3 has invalidated the slice 5.2.4 cold-start path; flag if broken). |
| 1.6 | Lenin-PC → Realme: pair-invite, then on Realme tap **Decline** on the invite notification without opening the app. | Lenin-PC's `[sharer.security.invite]` log shows the decline arrived; modal on Lenin-PC shows declined. **No** app foregrounding on Realme. |

**Pass criteria**: every action button + body tap routes correctly on
both platforms; no duplicate Windows toasts; cold-start route works.

---

## 2. Slice 5.3 — end-to-end chunk encryption

The wire shape changed: every signed `/upload` now carries an
`X-Sharer-TransferId` header and the body is AES-256-GCM-framed
ciphertext. Both ends had to be updated; either side running pre-5.3
code will cause a 401.

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Lenin-PC → Realme: tiny file (a few KB). | Saves, contents byte-for-byte identical to source. Lenin-PC log line shows `encrypted=true wireSize=…`; Realme log shows `encrypted=true` on receive start. |
| 2.2 | Realme → Lenin-PC: medium file (≥ 1 MB so it spans multiple chunks; e.g. a photo). | Saves, contents byte-for-byte identical to source. Both logs show `encrypted=true`. |
| 2.3 | Realme → Lenin-PC: send a file ≥ 50 MB. | Streams to disk without OOM (Realme's RAM stays flat — chunks are 32 KB plaintext / 32 800 B on the wire). Saved file matches source. |
| 2.4 | Lenin-PC → Realme: a 0-byte file (`empty.txt`). | 200 OK on the wire; saved file is 0 bytes (one all-zero-plaintext frame round-tripped). |
| 2.5 | While a large transfer is in flight, kill Wi-Fi on the receiver mid-transfer. | Sender side surfaces a failed transfer + clear error message; receiver side shows no partially-decrypted file (the in-flight `_handleUpload` deletes on error). |
| 2.6 | Send the same large file twice in a row. | Each transfer uses a fresh `transferId` (logs show two different base64 ids). Both saved correctly; receiver renames the second on collision (`foo (1).bin`). |

**Pass criteria**: every transfer round-trips byte-perfect, RAM stays
bounded, partial files don't survive aborts.

**Negative test (manual, optional)**: with both apps closed, on the PC
`flutter run --dart-define=…` would normally let you patch a constant.
Skip this — the GCM tag is the canary.

---

## 3. Slice 5.4 — forget / rediscover

### 3.a — Peer-IP cache (closes the bonsoir flake)

| # | Action | Expected |
|---|--------|----------|
| 3.a.1 | Realme → Lenin-PC: send any file (with both apps freshly started — no cache yet). | First upload uses the bonsoir-resolved `peer.host`. Lenin-PC's server log shows `peer-forgot-you`-class line `cacheAddress` (the response side will cache as part of the verified `/upload`). |
| 3.a.2 | After 3.a.1, immediately send a second file Realme → Lenin-PC. | Realme log shows `prefer cached host=…` if the cached host differs from bonsoir's. (May log identical hosts if bonsoir hasn't drifted — that's fine.) |
| 3.a.3 | The historical Realme bonsoir flake (peer.host overwritten with `192.168.68.56` — Realme's own IP). | If the flake reproduces, Realme should still complete the upload because the cached IP from the prior round-trip is preferred. **No** `HandshakeException` on a paired-peer send. |

### 3.b — Proactive forget (`POST /peer-forgot-you`)

| # | Action | Expected |
|---|--------|----------|
| 3.b.1 | Both devices paired. On Lenin-PC, open Devices, tap the trash icon next to **Realme**. | **Silent** — no confirmation dialog. Snackbar `Forgot Realme`. The Lenin-PC PairedDevices list drops Realme. **Realme** receives a `peer_unpaired` notification ("Lenin-PC unpaired"). After dismissing, Realme's Devices list also no longer shows Lenin-PC. |
| 3.b.2 | Re-pair both devices. Now on Realme tap trash next to Lenin-PC. | Same outcome, mirrored. Lenin-PC gets a `peer_unpaired` toast. |
| 3.b.3 | With Realme unpaired (after 3.b.1) but the app still running, on Lenin-PC try to send a file to Realme via the peer list. | The peer is no longer in the paired set; tap goes to the Pair-First sheet. |

### 3.c — Reactive forget (401 on a stale pair)

| # | Action | Expected |
|---|--------|----------|
| 3.c.1 | Wipe Realme's PairedDevices store: `flutter clean` + reinstall debug build (this also regenerates Realme's Ed25519 identity). On Lenin-PC, do **not** clean — the legacy entry for Realme is now stale. From Lenin-PC, attempt to send a file to the (still-listed-on-PC) Realme. | Lenin-PC's log shows `signature mismatch` rejected by Realme → `Send failed` with `Upload failed: 401`. Lenin-PC also fires `recordReactive401` and removes the stale Realme entry. Lenin-PC user sees a "Realme unpaired" notification. |
| 3.c.2 | After 3.c.1, refresh Lenin-PC's Devices screen. | Realme is gone. The transfer entry shows `failed`. |

### 3.d — Network watcher quirk regression

| # | Action | Expected |
|---|--------|----------|
| 3.d.1 | Both paired. Untrust the home Wi-Fi on Realme (Diagnostics → tap Untrust). Now send Lenin-PC → Realme. | Transfer **succeeds**. Trust gates discoverability, not authorization (slice 5.4 didn't change this — sanity check that 5.3 / 5.4 didn't accidentally regress §5 of `docs/v1/security.md`). |

**Pass criteria**: forget is silent on the trigger side, notification on
the forgotten side; reactive 401 catches stale pairs without user
involvement; the network watcher remains a discoverability gate only.

---

## 4. Slice 5.5 — Android share-sheet (Windows deferred)

| # | Action | Expected |
|---|--------|----------|
| 4.1 | On Realme, open Photos. Pick one image, tap Share. | **Sharer** appears in the share-sheet target list. |
| 4.2 | Tap Sharer in the share sheet (with the app **not running**). | Sharer cold-starts, the Home screen renders with a `Sharing <filename>` banner at the top. |
| 4.3 | Tap **Lenin-PC** in the peer list while the share banner is up. | The shared image is transferred to Lenin-PC. Banner clears, snackbar `Sending <name> → Lenin-PC…` appears. Saved file on PC matches the original. |
| 4.4 | Repeat 4.1 but with Sharer **already running** in the foreground. | The banner appears in-place (no cold start). Same transfer flow works. |
| 4.5 | On Photos pick **multiple** images, tap Share, tap Sharer. | Banner says `Sharing N files`. Tapping Lenin-PC sends all of them; snackbar reflects `N files`. |
| 4.6 | Open Sharer, share a file in (banner appears), tap the **X** on the banner. | Banner clears without sending. The cached temp files in `cacheDir/share_*` are deleted (verify with `adb shell run-as com.example.sharer ls cache`). |
| 4.7 | Try the equivalent on Windows (no share-sheet integration yet). | The Windows Share UI does **not** list Sharer. Document as expected — the Windows path is a deferred 5.5.x. |

**Pass criteria**: ACTION_SEND + ACTION_SEND_MULTIPLE both work; routing
to a paired peer streams from the cached temp file; multi-select bundles
into one banner; cancel tidies up.

---

## Reporting back

When you've finished a section (or hit something blocking), drop the
relevant `logs/*.txt` into the repo. Claude reads them automatically;
no need to say "see logs". Tell Claude only:

1. Section number(s) you ran.
2. Pass / fail per row.
3. The few lines of the device log that look most relevant.

Bugs become point-release commits (`5.2.4.1`, `5.3.1`, `5.4.1`, etc.)
shipped one-at-a-time the old per-slice way.

---

## Out of scope for this batch (still pending in the v1 plan)

- Windows Share contract registration (MSIX packaging) — **5.5.x**.
- iOS Share Extension — out of v1 (OQ-9, no Apple Developer account).
- Internet relay / cross-network paired peers — slice 6.x.
- Exportable encrypted offer file for offline pair seeding — slice 7.x.
- Stale-pair "yellow dot" badge in Devices — folded into the
  reactive-401 / proactive-forget paths above; if the user wants a
  visual badge for "haven't seen this peer in N hours" it's a small
  follow-up.
