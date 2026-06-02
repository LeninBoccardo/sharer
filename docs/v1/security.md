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

A short-numeric-code fallback ("type 6 digits") was envisioned for when the camera path is unavailable (e.g. desktop ↔ desktop with no webcam). The QR offer does carry a single-use 6-digit code (expires in 60 s, bound to a one-shot challenge so it can't be brute-forced offline).

**Implementation status (v1):** a *typed-code-only* pairing path — reconstructing a full offer from 6 digits alone — is **not built and is deferred to v2.** The QR carries the PSK, public key, cert fingerprint and endpoints; 6 digits cannot rebuild that without a new code→key exchange (a server-side offer registry keyed by code), which v1 deliberately does not add. The camera-less need is already met another way: the **LAN pair-invite + fingerprint flow (§6)** pairs two devices with no camera at all — tap the peer → "Send pair invite" → both screens confirm the same 6-digit fingerprint. A future typed-code QR replacement would build on §6 by letting the user *type* that fingerprint instead of comparing it on-screen; deferred to v2.

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

### 5. Network watcher → discoverability gate ONLY (never an authorization mechanism)

**Hard rule, restated for clarity:** trusting a network changes *what your device announces and accepts as discoverable*, never *who can push files to you*. Authorization is the pairing, full stop. A modified Sharer-imposter on a Wi-Fi the user trusts must not be able to deliver files just because it's on the same SSID.

Concretely, the watcher polls SSID + subnet every ~5 s. If the current network is not in the user's trusted-network list, the device enters **quiet mode**:

- **Stop** the mDNS announcer. The device does not broadcast `_sharer._tcp` presence.
- **Stop** registering the `/pair-invite` route on the HTTP server. LAN-invite pairing requires explicit network trust on both sides.
- **Keep** the HTTP server bound and the `/upload` route active. Paired peers that already know this device's IP (from peer cache) and pinned cert can still reach it via cached IP. Layers 2–4 (PSK, HMAC, TLS pinning, chunk encryption) remain the security boundary.
- **Keep** the passive mDNS listener running. If a paired peer is also on this unknown network and announces itself (e.g. because *they* trust this network), we still discover them.
- Surface a banner: *"On unrecognized network — discoverability off. Paired devices can still reach you."* The banner offers a one-tap "Trust this network" action that adds the current SSID + subnet to the trusted list and resumes announcing.

This means:

- A guest on a strange Wi-Fi can't see your device in their browser, but your laptop at home can still push you a file (it has your IP cached and your cert pinned, and signs every chunk with the per-pair key).
- If you wander into a new network that *is* your friend's home Wi-Fi where you've already paired with their devices, transfers still just work — possibly with some discovery delay until either side trusts the new network and resumes announcing.
- The trust boundary is the **pairing**, not the network. The watcher is a privacy/discoverability control, not a security control.

#### Asymmetric trust: paired-but-network-untrusted scenarios

A subtle case the model has to get right: A trusts network N; B is paired with A but does *not* trust N; both are on N. A third, unpaired device X on N tries to discover and invite both. Expected behavior:

- X discovers A via mDNS (A announces). X cannot discover B (B does not announce on N).
- X invites A → A's `/pair-invite` is registered (A trusts N) → A's invite UI fires.
- X cannot reach B at all on N: B's `/pair-invite` route is unregistered, and X has no mechanism to bypass that.
- A → B (already paired) transfers continue to work over N because the `/upload` route is always bound and B accepts A's signed, chunk-encrypted requests regardless of B's network trust state.

The right way to read this: from any unpaired observer on N, B simply does not exist on N. The only path to B from outside the existing pair-ring is a future internet relay (post-v1, see open-questions OQ-9).

### 6. Pair invite over the LAN — authenticated DH with fingerprint verification

QR pairing is the primary path. But devices that are already on a trusted network and don't have a camera-to-screen line of sight (two phones across a room, two desktops) need a QR-less path. The naïve approach — "send the PSK over the LAN since it's trusted" — is unacceptable: anyone passively sniffing the LAN, including a malicious ISP technician on a friend's home network the user has trusted, would capture the PSK in plaintext and forge requests forever after.

The protocol used instead is **authenticated Diffie–Hellman with a short verification fingerprint**:

```text
1. A → B  POST /pair-invite        { A_id, A_name, A_ephemeral_X25519_pubkey, nonce,
                                     signed by A's long-term Ed25519 key }
2. B's app surfaces a modal: "Pair with <A_name>?" — Accept / Decline
3. On Accept, B generates an X25519 ephemeral keypair.
4. shared = HKDF-SHA256(X25519(B_priv, A_pub) ‖ A_pub ‖ B_pub)
   → 32 bytes used as the long-term per-pair PSK.
5. B → A  response                 { B_id, B_name, B_ephemeral_pubkey,
                                     signed by B's long-term Ed25519 key }
6. Both sides compute the same PSK and the same 6-digit fingerprint:
   fingerprint = first 20 bits of HMAC-SHA256(PSK, "verify") rendered as 6 digits.
7. Both screens display the fingerprint in a modal-blocking sheet.
   User on each side taps "Matches" or "Doesn't match".
8. Both confirms received → pair stored on both sides with the same PSK.
   Either "Doesn't match" or any timeout → both sides discard ephemeral state.
```

Why this construction:

- **No PSK on the wire.** A passive LAN sniffer learns the public ephemeral keys but cannot derive the shared secret.
- **MITM detection.** A LAN attacker who relays both halves can establish a separate shared secret with each side, but that produces *two different fingerprints*. Both screens show different numbers, the user notices, both abort.
- **Identity binding.** Long-term Ed25519 signatures on the invite and response ensure the public ephemeral keys came from the claimed device, not an imposter who copied A's name and IP.

### 7. Long-term device identity (Ed25519 keypair)

Each device generates an Ed25519 keypair on first launch. The private key lives in `flutter_secure_storage` — Keystore-backed on Android, DPAPI-backed on Windows, Keychain-backed on iOS, software on desktop Linux. The deviceId is **derived** from the public key: `deviceId = first 16 hex chars of SHA-256(publicKey)`. Renaming the device does not change the deviceId; resetting the keypair (e.g. user-initiated "factory reset") does, and is treated as a new device.

This replaces the UUID-based deviceId from slices 4.1–4.3. An attacker on the LAN can fabricate any name and IP, but cannot fabricate a matching deviceId without finding a SHA-256 preimage of an existing public key. Every signed request — pairing handshakes, pair invites, file uploads — carries a signature verifiable against the deviceId's underlying public key, which is exchanged at pairing time and pinned alongside the cert fingerprint.

The hot-path file-transfer signature is still HMAC-SHA256 with the per-pair PSK (faster than asymmetric per-request). Pairing-time signatures are the only Ed25519 verifications on the critical path.

**Hardware-backed attestation** (Android Keystore attestation, iOS Secure Enclave, TPM on Windows) is a v2 polish item — it strengthens the "the private key really did come from a non-rooted device" claim. v1 ships with `flutter_secure_storage`'s default backing.

### 8. End-to-end encrypted chunks (slice 5.3)

Per-request HMAC authenticates *who* sent the bytes. It does not encrypt them. Two threats motivate adding chunk-level encryption on top of TLS:

- **(a) Defense-in-depth on a LAN you trust but a third party has tampered with.** Concrete scenario: user marks friend's home Wi-Fi as trusted, ISP technician has previously installed a sniffer on that LAN. TLS protects the byte stream, but a TLS misconfiguration or downgrade on either endpoint exposes plaintext. Per-chunk encryption survives that.
- **(b) Internet relay (post-v1).** Paired peers across NATs route through a small relay. The relay must never see plaintext. TLS-to-relay is not enough; the relay terminates TLS by definition.

Construction:

```text
For each transfer:
  transferKey = HKDF-SHA256(IKM=PSK, salt=transferId, info="sharer-transfer-v1", 32 bytes)

For each chunk i (16–64 KB):
  nonce       = transferId(8B) ‖ chunkIndex(4B) ‖ random(0)  // 12 bytes total
  ciphertext  = AES-256-GCM(transferKey, nonce, plaintext_chunk, AAD=chunkHeader)
  wire_chunk  = chunkIndex(4B) ‖ ciphertext_with_tag(N+16B)

Receiver:
  Verifies chunkIndex monotonic. Decrypts each chunk, streams plaintext to disk.
  GCM auth tag failure → abort transfer, delete partial file.
```

Per-chunk auth tags catch single-bit tampering at the granularity of one chunk. Decryption is streaming — plaintext never accumulates in memory. The transferKey lifetime is one transfer; PSK is never used directly to encrypt bytes.

> **HKDF input mapping (implementation note).** The per-transfer key uses the PSK as the HKDF input keying material (IKM) and the fresh per-transfer `transferId` as the HKDF *salt* — not as bytes concatenated into the IKM. Concretely: `transferKey = HKDF-SHA256(IKM = PSK, salt = transferId, info = "sharer-transfer-v1", L = 32)`. Both placements bind every transfer to a unique key derived from the long-term secret plus per-transfer entropy; we use salt because that is HKDF's purpose-built input for non-secret per-derivation diversifiers and it keeps the IKM a clean 32-byte secret. The `transferId` is 12 random bytes (audit #12); its full width feeds the salt, while only its first 8 bytes also seed the GCM nonce prefix.

### Why we kept the watcher at all

It would be defensible to drop the SSID check entirely now that pairing handles authentication. We keep it because:

- Suppressing announcements on unknown networks reduces fingerprinting (no broadcast of "Lenin's iPhone" on a coffee-shop SSID).
- It avoids unnecessary multicast traffic on networks where there are unlikely to be paired peers.
- It scopes the LAN-invite path (`/pair-invite`) to networks the user has explicitly approved, so an attacker on a hostile Wi-Fi can't even try to invite.

If the watcher proves to add complexity without measurable benefit during v1 implementation, dropping it is a clean follow-up. Document the call as a new OQ if we revisit.

## Implementation order

1. ✅ `_sharer._tcp` service type + SSID/subnet trust gate.
2. ✅ Pairing UI (QR) + PSK storage + HMAC signing (slices 4.1–4.3).
3. **▶ Pairing-required uploads (slice 4.4).** Server rejects unsigned `/upload` with 401 regardless of network trust.
4. Long-term Ed25519 device identity (slice 4.5). DeviceId becomes a public-key fingerprint.
5. LAN pair invite via DH+fingerprint (slice 4.6).
6. TLS + self-signed cert pinning (slice 5.1).
7. Background delivery on Android+Windows; iOS deferred (slice 5.2).
8. End-to-end chunk encryption (slice 5.3).
9. Forget/rediscover consistency layers (slice 5.4).
10. OS share-sheet integration (slice 5.5).

## Key storage

- Long-term Ed25519 private key, per-pair PSKs, TLS cert private keys: `flutter_secure_storage` (Keystore-backed on Android, DPAPI-backed on Windows, Keychain-backed on iOS, software-backed on desktop Linux).
- Cert public material + paired-peer registry: app's secure preferences / sqlite, encrypted at rest by the OS keystore.
- Peer cache (last-known IPs): plain preferences — no secrets, just routing hints.

## What this model deliberately does NOT do

- No central account / login. Pairing is purely local.
- No revocation server. To unpair, the user removes the peer on their device; slice 5.4's forget/rediscover heuristics surface "this peer seems to have forgotten you" so trust stays bilaterally consistent.
- No forward secrecy on the long-term per-pair PSK. The per-transfer key is fresh (HKDF with the PSK as keying material and a random transferId as the salt), so compromise of one transfer does not compromise others.
- No "auto-accept invites on trusted networks" toggle, ever. This would collapse the model — any device on the LAN could pair silently.
- No `/pair-invite` outside trusted networks. Even paired peers cannot issue invites on a network neither side trusts.
