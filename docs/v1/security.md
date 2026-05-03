# v1 — Security model

## Threat model

The app operates inside a trusted home LAN. The realistic threats are:

1. A guest device on the same Wi-Fi sending files to your devices uninvited.
2. A guest device receiving files from your devices uninvited.
3. The phone roaming to an untrusted network (coffee shop, hotel) and continuing to expose the share server.
4. A malicious actor on the LAN attempting to MITM a transfer between two paired devices.

Out of scope (won't defend against): a state-level attacker on your LAN, malware on a paired device, physical theft of an unlocked, paired device.

## Layers (cheap → strong)

### 1. Discovery filter — `_sharer._tcp` mDNS service type

Only devices announcing the custom service type appear in peer lists. Not a security boundary on its own (anyone who knows the service type can announce), but it keeps random Cast / Spotify / printer announcements out of the UI.

### 2. Pairing (the real boundary)

Devices pair **once per pair of devices**, via QR code:

```text
Device A: tap "Add device" → shows QR encoding (deviceId, PSK, certFingerprint)
Device B: tap "Scan device" → camera reads QR → stores triple in secure storage
                            → optional reverse exchange so A also stores B's certFingerprint
```

PSK is 256 bits, generated at first run, stored in platform secure storage (Android Keystore / Windows DPAPI via `flutter_secure_storage`).

A short-numeric-code fallback ("type 6 digits") is provided for when the camera path is unavailable (e.g. desktop ↔ desktop with no webcam). Codes are single-use, expire in 60 s, and are bound to a one-shot challenge so they can't be brute-forced offline.

**Unpaired peers are not shown in the peer picker.** They appear in a separate "nearby (not paired)" section that requires explicit tap-through to start a pair flow.

### 3. Per-request HMAC signature

Every HTTP request between paired peers carries:

```http
X-Sharer-Device:    <deviceId of sender>
X-Sharer-Timestamp: <unix ms>
X-Sharer-Nonce:     <random 128-bit>
X-Sharer-Sig:       HMAC-SHA256(PSK, method | path | timestamp | nonce | sha256(body))
```

Receiver validates:

- `deviceId` is a known paired peer (PSK lookup).
- `timestamp` is within ±30 s of local clock (replay window).
- `nonce` not seen in last 60 s (in-memory ring buffer).
- HMAC matches.

Reject otherwise; do not leak which check failed.

### 4. TLS with self-signed cert pinning

Each device generates a self-signed cert at first run. The fingerprint is exchanged during pairing (carried in the QR payload). All traffic runs over HTTPS; the client refuses any cert whose fingerprint isn't pinned for the target `deviceId`.

This defeats LAN MITM even if the attacker knows the PSK (which they shouldn't, but defense in depth).

### 5. Network watcher → discoverability gate (NOT a transfer kill-switch)

The user requirement: **pairing is a one-time identifier**. Once two devices are paired, they must be able to transfer files no matter which Wi-Fi they meet on. Tearing down the HTTP server on every unfamiliar network would force re-pairing in practice and is therefore disallowed.

Refined behavior — the watcher polls SSID + subnet every ~5 s. If the current network is not in the user's trusted-network list, the device enters **quiet mode**:

- **Stop** the mDNS announcer. The device does not broadcast `_sharer._tcp` presence.
- **Keep** the HTTP server running. Paired peers that already know this device's IP (from peer cache) and pinned cert can still reach it. Layers 2–4 (PSK, HMAC, TLS pinning) remain the security boundary.
- **Keep** the passive mDNS listener running. If a paired peer is also on this unknown network and announces itself (e.g. because *they* trust this network), we still discover them.
- Surface a banner: *"On unrecognized network — discoverability off. Paired devices can still reach you."* The banner offers a one-tap "Trust this network" action that adds the current SSID + subnet to the trusted list and resumes announcing.

This means:

- A guest on a strange Wi-Fi can't see your device in their browser, but your laptop at home can still push you a file (it has your IP cached and your cert pinned).
- If you wander into a new network that *is* your friend's home Wi-Fi where you've already paired with their devices, transfers still just work — possibly with some discovery delay until either side trusts the new network and resumes announcing.
- The trust boundary is the **pairing**, not the network. The watcher is a privacy/discoverability control, not a security control.

### Why we kept the watcher at all

It would be defensible to drop the SSID check entirely now that pairing handles authentication. We keep it because:

- Suppressing announcements on unknown networks reduces fingerprinting (no broadcast of "Lenin's iPhone" on a coffee-shop SSID).
- It avoids unnecessary multicast traffic on networks where there are unlikely to be paired peers.
- It gives the user a visible, actionable signal ("you're on an unfamiliar network") that encourages them to think before pairing new devices on an untrusted Wi-Fi.

If the watcher proves to add complexity without measurable benefit during v1 implementation, dropping it is a clean follow-up. Document the call as a new OQ if we revisit.

## Implementation order

1. `_sharer._tcp` service type + SSID/subnet kill-switch (cheap, lets transfers happen at all).
2. Pairing UI + PSK storage + HMAC signing (before any real-world exposure).
3. TLS + cert pinning (before v1 ships).

Skipping straight to step 3 isn't worth the up-front cost; do it in order so each step is testable.

## Key storage

- PSKs and cert private keys: `flutter_secure_storage` (Keystore on Android, DPAPI-backed on Windows).
- Cert public material + paired-peer registry: app's secure preferences / sqlite, encrypted at rest by the OS keystore.
- Peer cache (last-known IPs): plain preferences — no secrets, just routing hints.

## What this model deliberately does NOT do

- No central account / login. Pairing is purely local.
- No revocation server. To unpair, the user removes the peer on their device; the other side will start failing HMAC checks (with no surfaced reason) and eventually the user will unpair from that side too.
- No forward secrecy beyond what TLS provides. Long-term PSK is acceptable for the threat model; rotate on device reset.
