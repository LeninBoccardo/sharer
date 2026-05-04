# v1 — Open questions

Unresolved design calls. Each entry should be **closed** (with the decision and a link to where it's documented) before the relevant code lands. Stale items are bugs.

> **Status (2026-05-03):** the initial v1 round (OQ-1 through OQ-8) has been answered by the user — see `**Answer:**` lines on each item below. The substantive decisions have been folded into [overview.md](overview.md), [architecture.md](architecture.md), [security.md](security.md), and [ux.md](ux.md). These items are kept here as a frozen record of the original questions and answers; do not delete. New open questions should be appended below as **OQ-9**, **OQ-10**, etc.

## OQ-1 — Direct Share in the Android system share sheet

**Question:** Do we register paired peers as Android Direct Share targets so they appear *inside* the system share sheet (skipping the in-app peer picker), or do we always route through our own peer picker after the user taps the app entry?

**Trade-off:** Direct Share saves one tap on the happy path (the goal click-budget is 1 tap inside the app — Direct Share would make it 0). It's also fragile across Android versions and OEM share-sheet skins. Routing through our own peer picker is universally consistent and easier to style.

**Default if undecided:** ship with our own peer picker; add Direct Share as a v1.1 enhancement.

**Answer:** ship our own peer picker, consistency have higher value sometimes

## OQ-2 — Auto-accept from paired devices

**Question:** Should incoming transfers from paired devices be auto-accepted by default, or always prompt?

**Trade-off:** Auto-accept is faster and matches the mental model of "these are *my* devices." Always-prompt prevents unattended-device surprises (someone with access to a paired phone could push files to your laptop without you noticing).

**Default if undecided:** always prompt in v1; per-peer "trust to auto-accept" toggle deferred to v1.1.

**Answer:** stick to the default if undecided

## OQ-3 — Pairing model strength

**Question:** Stick with the QR-based pairing + PSK + cert pinning model (described in [security.md](security.md)), or accept a lighter "open LAN, anyone speaking the protocol can send" model?

**Default (assumed):** full pairing model. To be confirmed by the user.

**Answer:** QR-based pairing can be done IF it is only necessary once, if this must be redone everytime we change SSID I prefer open LAN approach. In other words QR-based must work as an one time identifier that guarantee that device is a trustable one, no matter which SSID devices meet each other.

## OQ-4 — Background behavior on mobile

**Question:** Always-on announcer (instant peers, persistent notification, small battery cost) vs wake-on-share (zero idle cost, ~1–3 s discovery delay) vs hybrid (passive listener always on + peer cache + active announce only when needed)?

**Default (assumed):** hybrid. To be confirmed by the user.

**Answer:** hybrid

## OQ-5 — Share-sheet platforms in v1

**Question:** v1 ships native share-sheet integration on Android + Windows only, deferring iOS Share Extension and macOS NSSharingService to a later version?

**Default (assumed):** yes, Android + Windows only for v1. To be confirmed by the user.

**Answer:** use assumed

## OQ-6 — Versioning of these docs

**Question:** Per-version folders (`v1/`, `v2/`, …) aligned to releases vs per-feature folders (`001-discovery/`, `002-transfer/`, …)?

**Default (assumed):** per-version, as currently structured. To be confirmed by the user.

**Answer:** use assumed

## OQ-7 — Default download folder on Android

**Question:** Use the public `Download/` folder (visible in Files app, requires `WRITE_EXTERNAL_STORAGE` / scoped storage handling) vs app-private storage with a "view in Files" intent?

**Trade-off:** Public Downloads matches user expectation but the scoped-storage rules on Android 11+ are awkward. App-private is friction-free to implement but the user has to go through us to see their files.

**Default if undecided:** public `Download/` via the MediaStore API on Android 10+; app-private fallback only if MediaStore is unavailable.

**Answer:** use default, seems to be a good solution

## OQ-8 — Brand / accent color

**Question:** What's the single accent color?

**Default if undecided:** punt to first UI implementation pass; pick something defensible (probably a saturated teal or indigo) and revisit.

**Answer:** of course this must be something easy to change later. For now stick to the default using indigo

## OQ-9 — iOS support in v1

**Question:** Is iOS in v1's launch scope, with the implication of either an APNs relay we run (so background invite/transfer notifications reach killed apps) or a foreground-only experience?

**Trade-off:** iOS forbids long-lived background networking for non-VOIP/non-streaming apps. `BGAppRefreshTask` wakes are best-effort with no latency guarantee; local notifications fire only while the app is active or via APNs (which needs a server we don't have). A reliable iOS pair-invite-while-killed requires either running a small APNs relay or accepting that iOS users must keep the app foregrounded.

**Default if undecided:** iOS deferred to v2.

**Answer:** iOS is **out of scope for v1**. Lenin does not have an Apple Developer account ($99/yr; not affordable now). Code should not break the iOS build, but no iOS-specific features are guaranteed and no testing is performed against iOS. The foreground-only background limitation is a known v2 polish item; documented but not fixed.

## OQ-10 — Background delivery on Android + Windows (slice 5.2)

**Question:** Skip the v1-style "must have app open to receive invites and confirm transfers" and go directly to a foreground-service / tray-icon model that surfaces system notifications even with the UI hidden?

**Trade-off:** Foreground service on Android is a one-time investment (manifest entry, ongoing notification). It enables real "leave the app closed and still get a pair invite" UX which matches user expectations. v1 of just-keep-the-app-open is an inferior baseline.

**Default if undecided:** ship v2 directly.

**Answer:** ship v2 directly. Android foreground service for the mDNS listener + HTTP server while paired peers exist; Windows tray icon with run-on-startup option; `flutter_local_notifications` for incoming transfer prompts and pair invites. iOS is foreground-only per OQ-9.

## OQ-11 — Encryption scope (slice 5.3)

**Question:** Is per-chunk end-to-end encryption (a) defense-in-depth on LAN over TLS, (b) required to keep a future internet relay from seeing plaintext, or both?

**Trade-off:** TLS already encrypts on the LAN. Adding chunk encryption costs ~5–10% throughput. If the relay use case is in scope, chunk encryption is non-optional and must land before any relay work; if only LAN, it's polish.

**Default if undecided:** both. Land before the relay slice.

**Answer:** **both, mandatory.** Concrete LAN scenario motivating defense-in-depth: user marks a friend's home Wi-Fi as trusted and later learns a malicious ISP technician installed a sniffer on it before the visit. TLS protects bytes if both endpoints stayed configured correctly; chunk encryption survives a TLS misconfiguration or downgrade. Relay scenario is a future feature but requires the same primitive. Construction: `transferKey = HKDF(PSK ‖ transferId)`, AES-256-GCM per chunk with `nonce = transferId(8B) ‖ chunkIndex(4B)`, streaming decrypt to disk.

## OQ-12 — Hardware-backed device identity (post-v1)

**Question:** Should the long-term Ed25519 device key (slice 4.5) be hardware-attested — Android Keystore attestation, iOS Secure Enclave, TPM on Windows — or is `flutter_secure_storage`'s default backing sufficient for v1?

**Trade-off:** Hardware attestation lets a paired peer cryptographically verify "this device key really did originate inside non-rooted hardware," ruling out emulator-based imposter devices. It requires platform code per OS and rate-limited attestation calls. `flutter_secure_storage` already uses Keystore/DPAPI/Keychain *as backing* — the keys never appear in plaintext on disk — but does not expose attestation chains.

**Default if undecided:** v1 uses `flutter_secure_storage`'s default. Attestation is a v2 polish item.

**Answer:** v1 uses `flutter_secure_storage` default backing (hardware-backed on most modern Android/iOS, software-backed on Windows DPAPI / desktop Linux). Attestation deferred to v2. Document the gap so a future audit knows the strength of the identity claim across platforms.
