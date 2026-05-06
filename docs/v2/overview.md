# v2 — cross-platform expansion + cross-network transfers

This document captures the architectural decisions made for v2 during a
design conversation after v1 (slices 1–5.5) finished. It is not yet an
implementation plan — it is the **why and the shape** so a future
implementer (Claude or otherwise) can pick up without re-litigating the
trade-offs.

When `docs/v2/` later grows architecture / security / ux / open-questions
files like v1 does, this overview is the source those should split from.

---

## Goals

v2 expands two axes:

1. **Platform reach** — add macOS, Linux, and iOS to the v1 set
   (Windows + Android).
2. **Network reach** — paired peers can transfer when not on the same
   LAN.

The hard requirement v1 set still holds: **the LAN-only path stays
zero-network-dependency**. Adding cloud infrastructure must not turn
"share between two devices on my Wi-Fi" into "needs internet."

---

## Platform plan

| Platform | Lift | Notes |
|----------|------|-------|
| **Windows** | (v1) | Already supported. |
| **Android** | (v1) | Already supported. |
| **macOS** | small | Most plugins already support it (`flutter_secure_storage`/Keychain, `bonsoir`/NSNetService, `shelf`, `tray_manager`, `window_manager`). Real work: confirm `mobile_scanner` works on the Mac webcam (or rely on the typed-code QR fallback), wire `flutter_local_notifications` macOS init, codesign for distribution. |
| **Linux** | small | `bonsoir` uses **Avahi** on Linux; `flutter_secure_storage` needs `libsecret` / `gnome-keyring`. `mobile_scanner` doesn't support Linux — typed-code fallback only. Otherwise minor. |
| **iOS** | medium-large | Code-wise close to macOS. The blockers are (a) the always-on receive architecture doesn't fit iOS — see [#iOS deep dive] — and (b) Apple Developer account ($99/yr) is required for APNs + Share Extension distribution. |

Recommended order: **macOS → Linux → relay (slice 6.x) → iOS riding on
the relay.** Doing iOS before the relay forces a broken-by-design UX
("must keep app open") onto the iOS user from day one; doing the relay
first means iOS arrives with a real story.

---

## Networking model — three-tier routing

The shape that makes everything else fall out:

```
┌──────────────────────────────────────────────────────────┐
│  Tier 1: same LAN                                        │
│  ─────────────────                                       │
│  mDNS discovery + direct HTTP transfer.                  │
│  Zero internet dependency. All v1 code paths.            │
│                                                          │
│  Used when: peers find each other via mDNS.              │
│  Always preferred — fastest, cheapest, most private.     │
├──────────────────────────────────────────────────────────┤
│  Tier 2: different LANs, NAT hole-punching succeeds      │
│  ─────────────────────────────────────────────           │
│  STUN (free public server e.g. stun.l.google.com:19302)  │
│  + a tiny signaling server for peers to exchange         │
│  discovered IP/port info. The actual file bytes still    │
│  flow peer-to-peer over the internet.                    │
│                                                          │
│  Used when: paired peers are on different networks       │
│  and both are awake.                                     │
│  Succeeds for ~80–85% of NAT pairs.                      │
├──────────────────────────────────────────────────────────┤
│  Tier 3: relay fallback                                  │
│  ──────────────────────                                  │
│  Sender uploads ciphertext to S3 (encrypted with the     │
│  per-pair PSK). Server fires a wake signal to the        │
│  receiver. Receiver downloads and decrypts. S3 blob is   │
│  deleted after ACK. The relay never sees plaintext —     │
│  matches docs/v1/security.md §8(b) by design.            │
│                                                          │
│  Used when: hole-punching fails (~15–20% on hostile      │
│  NATs / CGNAT / symmetric NAT) OR the receiver is        │
│  asleep (iOS background — see #iOS deep dive).           │
└──────────────────────────────────────────────────────────┘
```

The bytes flow direct whenever they can. The relay is a fallback, not
the default.

This is the same shape **Tailscale** uses (their fallback is called a
DERP relay), and the same shape WebRTC and Syncthing use. We're not
inventing a new pattern — we're inheriting a well-trodden one.

---

## Infrastructure components

| Component | Provider | Cost (personal scale) |
|-----------|----------|----------------------|
| **STUN** | Free public server (Google `stun.l.google.com:19302` or similar). No infra to run. | $0 |
| **Signaling** | AWS Lambda + API Gateway. ~50–200 lines of code. Stores no state beyond an in-memory peer connection table — both peers POST their STUN-discovered IP/port, server matches them by inviteId, returns the peer's info. | $0 (free tier covers 1M req/mo). |
| **Push (iOS only)** | Apple Push Notification service. Requires APNs auth key from the Apple Developer account. | $0 (Apple-side); APNs is free. |
| **Relay storage** | AWS S3, presigned upload + download URLs, lifecycle rule to delete blobs after a few minutes if not already cleaned up by the ACK path. | ~$0 (free tier first year, pennies after). |
| **Coordinator runtime** | AWS Lambda. Single function or one-per-route. Language doesn't matter for this scale — Go, Node, Python, Rust all fit. Pick the one with fastest iteration speed for the implementer; Go's small binary + low cold-start is nice but invisible at personal volume. | $0 |

**Total expected cost at personal scale: $0/month**, plus the $99/yr
Apple Developer fee if iOS ships.

---

## iOS deep dive

iOS is the only platform where v1's architecture genuinely doesn't
work, because:

1. **No always-on background.** The HTTP server is suspended within
   ~5–30 seconds of the app leaving foreground (sometimes faster).
2. **mDNS announcements stop** when the app suspends.
3. **No equivalent of Android's foreground service** for keeping a
   long-lived TCP listener alive. (`audio`, `voip`, `location`
   background modes exist but Apple rejects misuse, and they don't
   really fit a file-transfer app.)

The fix involves two pieces, depending on direction:

### iOS sending (any LAN)

iOS is in the foreground (the user opened the app to hit send), so it
behaves like every other platform: tier 1 if same LAN, tier 2 if
different LAN, tier 3 if hole-punching fails.

**No iOS-specific logic needed.**

### iOS receiving — same LAN

Two sub-cases:

- **Sharer foregrounded on iOS** → tier 1 (pure LAN P2P, identical to
  Android in foreground). Zero internet dependency.
- **Sharer backgrounded on iOS** → app is suspended. Sender on the
  same LAN can't push directly because nothing is listening. Need to
  wake the iOS app via APNs first; once awake, the iOS app can fetch
  directly from the sender's LAN address (no S3 round-trip).
  Optimisation: try LAN-direct fetch first inside the wake window,
  fall back to S3 if the sender went offline meanwhile.

### iOS receiving — different LAN

iOS is suspended, sender is somewhere on the public internet:

- APNs wake → iOS gets ~30s of background runtime.
- In that window iOS downloads the encrypted blob from S3, decrypts
  with the per-pair PSK, saves, ACKs back.
- S3 blob deleted.

**Why not skip S3 and have iOS hole-punch to the sender during the
wake window?** Because hole-punching needs both peers awake and
coordinating live; iOS gets ~30 seconds, the sender may have moved
networks or gone offline since they fired the push. The ciphertext
sitting in S3 is the only reliable way to decouple "sender's online
moment" from "receiver's wake-up moment."

### Trade-off the user can make: pure-LAN iOS without internet

If the user accepts the UX that **Sharer must be foregrounded on iOS
to receive**, the iOS app drops the APNs/relay path entirely on the
LAN. This is exactly what LocalSend does on iOS. The cost: the user
must explicitly open the app before someone pushes to them. Reasonable
trade-off if "I'm at home and want to send a photo to my iPhone right
now" is the primary use case.

The two postures aren't mutually exclusive: ship "must be foreground"
as the default for users without an Apple Developer account / paid
backend, and offer the APNs+relay path as an opt-in for users who
want unsolicited-receive.

---

## Where v1's design already paid for v2

A lot of v2 is cheap *because* v1 made the right choices ahead of time:

- **Per-pair PSK + per-transfer AES-256-GCM** (slice 5.3) — the relay
  is untrusted infrastructure by construction. S3 sees ciphertext and
  metadata, never plaintext. `docs/v1/security.md` §8(b) flagged this
  as the explicit motivation.
- **Cert pinning + HMAC per request** (slices 4.x + 5.1) — direct
  P2P over the internet inherits the same trust model. No new auth
  layer needed; the relay path piggybacks on existing per-pair keys.
- **Long-term Ed25519 device identity** (slice 4.5) — `deviceId` is
  already a stable cross-network fingerprint. The signaling server
  uses it as the lookup key.
- **Peer-IP cache** (slice 5.4) — the same store extends naturally to
  cache the public IP discovered via STUN, so subsequent transfers
  skip a signaling round-trip when the cached endpoint still works.
- **`/peer-forgot-you` + reactive 401** (slice 5.4) — already give us
  bilateral pair lifecycle. No relay-side state about who is paired
  with whom is needed; pairs remain a purely peer-to-peer concept.

The cleanest way to read this: **v2 doesn't change the security model,
it just extends the transport.** The bytes still flow under the same
PSK + cert + chunk-encryption guarantees, regardless of whether they
went via LAN, hole-punched WAN, or relay.

---

## Open questions for v2

Numbered so they can be referenced as `OQ-2-N` in commit messages /
discussions:

- **OQ-2-1: relay implementation language.** Go vs Node vs Python on
  Lambda. Default: whatever the implementer iterates fastest in.
  No technical reason to commit yet.
- **OQ-2-2: hole-punching library.** Build STUN/ICE coordination
  ourselves (a few hundred lines of Dart) or pull in a Flutter
  WebRTC-style package? Unknown until we know how much of WebRTC's
  framing fits a one-file-at-a-time use case.
- **OQ-2-3: should APNs+relay be opt-in or default on iOS?** Default
  to "must be foreground" (pure-LAN, zero infra), make the relay
  path an opt-in toggle in settings? Or default-on if the user
  signed in with an Apple ID / has push tokens? Lean toward
  **opt-in** so the no-Apple-Dev-account user gets a working
  product.
- **OQ-2-4: who pays for the AWS account?** A single shared Lambda
  for all installs (Lenin's account; risk of pulling someone else's
  bill if it goes viral) vs a "bring your own AWS" config screen
  (more setup friction, no centralised cost). Probably start with
  shared, add BYO when the cost crosses ~$1/month, but document
  the BYO path early so it's not a rewrite later.
- **OQ-2-5: macOS / Linux Share contract.** Linux has no standard
  share contract; macOS has Share Extensions (separate Xcode
  target like iOS). Defer both to "share-sheet 2.x" sub-slices of
  v2, same as Windows Share contract was deferred from v1.
- **OQ-2-6: signaling server lookup key.** `deviceId` (Ed25519
  fingerprint) is the natural choice. But peers might want to
  initiate to a peer they haven't paired yet (not a v1 pattern, but
  v2 might rethink "pairing must precede transfer"). Defer until
  the relay UX is sketched.

---

## What this document is NOT

- Not an implementation plan. The slice breakdown for v2 will be
  written when v1 ships and validation surfaces the actual gap list.
- Not a security spec rewrite. v2 inherits v1's eight-layer model
  unchanged — see `docs/v1/security.md`.
- Not a UX spec. The "share to a peer on a different network" UX
  belongs in `docs/v2/ux.md` once we know more about the relay
  latency profile.

When this document grows the four siblings (`architecture.md`,
`security.md`, `ux.md`, `open-questions.md`), this overview should
shrink to just the goals + the platform plan + a TOC, like
`docs/v1/overview.md` does today.
