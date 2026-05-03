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
