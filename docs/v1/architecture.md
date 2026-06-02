# v1 — Architecture

## Layering (Clean Architecture)

```text
presentation/   Flutter widgets, state mgmt, share-sheet entry points
   │
   ▼
domain/         Pure Dart. Entities (Peer, Transfer, FilePayload),
                use-cases (DiscoverPeers, SendFile, ReceiveFile),
                abstract repository/service interfaces.
   ▲
   │
data/           Concrete adapters: shelf HTTP server, Dio client,
                bonsoir wrapper, secure storage, file system.
```

Dependencies point inward. `domain` imports nothing from `data` or `presentation` and contains no Flutter imports. Composition root (in `presentation` or a top-level `app/` module) wires concrete `data` implementations into the `domain` interfaces.

## Subsystems

Each subsystem is a separately testable module behind a `domain` interface.

| Subsystem | Always on? | Notes |
| --- | --- | --- |
| HTTP server (shelf) | Always on (any network, post-slice-5.1) | Streams uploads to disk; never buffers full files. Port 8080 default, fall back if taken. Authenticated by HMAC + cert pinning, so it's safe to leave running on unfamiliar networks. Until slice 5.1 lands, the server still trust-binds — but **every** `/upload` requires a valid signature regardless (slice 4.4). |
| `/upload` route | Whenever server is bound | Requires HMAC signature from a paired peer. **Unsigned requests are rejected with 401 even on trusted networks** (slice 4.4) — trust-network is never an authorization mechanism. |
| `/pair-invite` route | **Trusted networks only** (slice 4.6) | LAN-invite endpoint. Only registered when the network is trusted; absent on untrusted networks regardless of pair state. |
| HTTP client | On demand | Streams from disk. Uses connection pooling for chunked transfers. |
| mDNS announcer (`_sharer._tcp`) | **Trusted networks only.** | Implemented behind the [`MdnsBackend`](../../lib/data/discovery/mdns_backend.dart) interface (production: bonsoir; test: `FakeMdnsBackend`). Service name is **session-unique** (`sharer-<random>`) to avoid the platform NSD layer auto-renaming on local-cache collision (the "(2)" issue). Display name lives in the `name` TXT attribute. |
| mDNS listener | **Trusted networks only** (until pairing lands) | Same backend as the announcer. Maintains in-memory peer list keyed by `deviceId` (advertised in TXT). On untrusted networks the listener is fully torn down and the peer list cleared. **Once pairing exists (slice 4), the listener will stay active on untrusted networks too**, but UI will filter to paired peers only — so paired devices remain reachable on any Wi-Fi while strangers stay invisible. Until then, full silence on untrusted is the correct default. |
| Network watcher | Always on | Polls SSID + subnet every ~5 s. On unrecognized network, sets the announcer to quiet mode and surfaces a banner. **Does not stop the server.** Trust boundary is pairing, not network — see [security.md](security.md). |
| Peer cache | Persistent | Last-known peer IP + cert fingerprint per paired device, used for optimistic connect. Survives across networks so paired peers can be reached even when neither side is announcing. |

## Discovery orchestrator — strong rules

The mDNS orchestrator ([`MdnsPeerDiscovery`](../../lib/data/discovery/mdns_peer_discovery.dart)) follows these rules. They are enforced by the unit-test suite at [`test/data/discovery/mdns_peer_discovery_test.dart`](../../test/data/discovery/mdns_peer_discovery_test.dart) — any change here must keep them green.

1. **Discovery and broadcast are atomic with trust state.** When the network is trusted, both run; when it is not, neither runs. There is no partial state.
2. **Trust transitions are serialized via a desired-state reconciler.** Concurrent emissions on the trust stream cannot overlap their effects. The latest desired state always wins; intermediate states are coalesced. (Without this, an `_enable()` racing with an `_disable()` could leave discovery running on an untrusted network — observed pre-2.5 on real devices.)
3. **Peer list is cleared on untrust.** A peer that was visible on a trusted network must not linger after the user untrusts. Stale peer state is a security smell.
4. **Self is filtered by `deviceId` TXT attribute, not by mDNS service name.** The platform NSD layer auto-renames services on local collision (the "(2)" suffix). `deviceId` is stable per install.
5. **mDNS service names are session-unique** (`sharer-<random>`). A new random suffix on every broadcast prevents NSD renaming on the local cache. The user-visible name lives in the `name` TXT attribute and is read on the consumer side from there, falling back to the mDNS name.
6. **Subscribe before start.** Enforced inside [`BonsoirMdnsBackend.observe`](../../lib/data/discovery/bonsoir_mdns_backend.dart) — bonsoir's event stream drops anything emitted before listen attaches. Caught the hard way in slice 2.3.

### Bonsoir caveats absorbed by the backend wrapper

`bonsoir` is the most maintained Flutter mDNS package but has known quirks that the backend deliberately isolates:

- **TXT-record race on Android NSD** — late TXT updates can fire spurious `lost` + `found` event pairs with mismatched attributes. We dedupe by `deviceId` and tolerate the churn.
- **Non-platform-thread channel warning on Windows** — cosmetic; not actionable from our side.
- **Auto-rename on collision** — bonsoir does not suppress the platform behavior. We sidestep it with session-unique mDNS names (rule 5).

If bonsoir ever becomes unsuitable, swapping it out means writing a new `MdnsBackend` impl. Production code does not import `package:bonsoir` directly outside that file.

## Transport — strong rules

These are enforced by the test suite at [`test/data/transport/http_file_server_test.dart`](../../test/data/transport/http_file_server_test.dart) and [`test/data/security/`](../../test/data/security/). Any change here must keep them green.

1. **Pairing is the only path to `/upload`** (slice 4.4). The server returns 401 for any upload that fails HMAC verification — including unsigned uploads — *regardless* of network trust state. Network trust is a discoverability control, never an authorization mechanism.
2. **`/pair-invite` is registered only on trusted networks** (slice 4.6). It comes up when the watcher reports trusted, and is removed before the listener tears down on untrust. There is no path to invite-without-trust.
3. **In-flight pair handshakes are atomic.** A pending invite registry holds `(offerId, ephemeralKeypair, peerId, peerPublicKey, createdAt)`. Any failure path — timeout, user "Doesn't match", crash before fingerprint confirm — wipes the entry whole. There is no half-paired state.
4. **Process-death recovery is explicit, not automatic.** A persisted in-flight marker exists so an app crash mid-handshake is recoverable, but the next launch surfaces "Previous pairing was interrupted — re-pair?" rather than auto-resuming. Resuming a half-completed handshake is unsafe (peer may have moved on).
5. **DeviceId is a public-key fingerprint** (slice 4.5+). `deviceId = first 16 hex chars of SHA-256(Ed25519 publicKey)`. An attacker on the LAN cannot fabricate a deviceId without finding a hash preimage. The Ed25519 private key is in `flutter_secure_storage`; the public key is published in mDNS TXT and embedded in pair invites/responses.
6. **Per-pair PSK, never shared across pairs.** Each `PairedDevice` carries its own 32-byte PSK derived independently. Compromise of one pair never exposes another.
7. **Per-transfer key, derived not transmitted.** End-to-end chunk encryption (slice 5.3) derives `transferKey = HKDF-SHA256(IKM=PSK, salt=transferId)` per upload (transferId is the HKDF salt, not concatenated into the IKM). The PSK never encrypts bytes directly; the transferKey lifetime is one transfer.

### Pull endpoint (`GET /files/:id`) — deferred to v2

The original protocol sketch ([CLAUDE.md](../../CLAUDE.md), [APP_INITIAL_DOCS.md](../../APP_INITIAL_DOCS.md)) listed a `GET /files/:id` *pull* endpoint alongside `POST /upload`. **v1 is push-only.** The entire UX is "pick a peer → send"; no v1 surface ever initiates a pull, so a pull endpoint would be authenticated server + client code with zero callers — exactly the premature abstraction the [code conventions](../../CLAUDE.md) forbid until there is a second real caller. It is therefore **intentionally not implemented in v1 and deferred to v2**, where a "request a file from a peer" flow (or the cross-network relay, slice 6.x) would give it a genuine caller and a UX to drive it. Until then `/upload` (push) is the only transfer route.

## Hot path: share flow

This is the path that defines the app's perceived speed. Every step counts.

```text
1. User taps share in source app
2. OS dispatches ACTION_SEND / Windows Share contract → sharer launches into share UI
3. UI shows peer list, populated from THREE parallel sources:
     (a) peer cache  — instant, last-known IPs of paired devices
     (b) mDNS listener — already-listening, zero startup cost
     (c) fresh announce + listen burst — kicked off the moment share UI opens
4. User taps peer
5. Client begins streaming POST /upload immediately to cached IP (a),
   races against fresh-discovery IP (b/c) — first to ACK wins, the other is cancelled
6. Progress UI animates while bytes stream
```

**Optimization rules:**

- Never block the UI on (c) — show whatever (a)+(b) already have.
- Optimistic connect to cached IP starts within milliseconds of the peer tap; do not wait for any "are you online" probe.
- HTTP server stays prewarmed (already bound) on every network — paired peers can reach it via cached IP regardless of network trust.
- Cache invalidation: a cached IP that fails to ACK in ~500 ms is dropped from the cache; fresh discovery takes over.
- On unrecognized networks, fresh discovery (c) still runs but only announces if the user has explicitly trusted the network. (a) + (b) carry the load until then.

**Implementation status (v1): single-host pick, not a parallel race.** Step 5's "stream to the cached IP while racing fresh discovery — first to ACK wins" is **deferred to v2.** A literal race of two *uploads* is impossible without buffering the whole file (the body is a one-shot stream, never buffered), and the reduced "race a cheap connect probe, then upload to the winner" variant adds a probe round-trip plus a second TLS handshake precisely on the slow path — at odds with Principle #1 (speed). v1 instead selects one address up front in [`TransferServiceImpl._runUpload`](../../lib/data/transport/transfer_service_impl.dart): the cached IP while it is still fresh (≤ 12 h, audit #38), else the live mDNS host. A stale/dead cached IP is handled *after the fact* by the 12 h freshness bound and the reactive-forget path rather than by a pre-flight probe. The parallel cached-vs-mDNS connect race is a v2 reliability/perf item (it becomes more attractive once cross-network relay, slice 6.x, multiplies the candidate-address count).

## Background behavior

The goal is "leave the app closed, still receive files from paired peers." Android's policy on backgrounded networking forces a compromise: any process that keeps a TCP socket alive in the background must run as a foreground service with a visible notification. There is no documented escape hatch. The slice 5.2 model below threads the needle by making that notification as quiet as the OS allows; FCM relay alternatives are documented + rejected in [open-questions.md OQ-10](open-questions.md#oq-10).

### Android (slice 5.2)

- **Foreground service while paired count > 0.** Started when the user has at least one [`PairedDevice`](../../lib/domain/entities/paired_device.dart) and stopped when the last pair is forgotten. Type = `dataSync` (Android 14+ requirement). Implemented via [`flutter_foreground_task`](https://pub.dev/packages/flutter_foreground_task).
- **Idle notification on `IMPORTANCE_MIN`.** Channel `service_idle`. Title "Sharer", small monochrome icon, no sound, no peek, no lock-screen presence, no badge. Effectively a single collapsed line at the bottom of the notification shade — what WhatsApp's "connection" notification looks like.
- **Transfer notifications use a separate channel** (`transfer_active`, `IMPORTANCE_LOW` with progress) so heads-up + progress are visible during an actual transfer. The idle line and the transfer-active notification coexist on their two separate channels — the foreground-service notification (channel `service_idle`) is the OS-mandated FG notification and **cannot be cancelled while the service is running** (cancelling it means `stopService()`, which would drop the wake/wifi locks and let Android kill the in-flight receive). Because the idle line is `IMPORTANCE_MIN` (collapsed, silent, no peek, no lock-screen), the user effectively just sees the transfer-active heads-up; the two never compete for attention.
- **Runtime `POST_NOTIFICATIONS` (Android 13+).** First-launch prompt; on deny, fall back to in-app banners — the FG service still runs but its idle notification is silent (the OS-mandated visible notification is still there, just minimal).
- **Battery-optimization whitelist prompt.** OEMs with aggressive killers (Xiaomi, Oppo, OnePlus, Huawei) will kill the FG service anyway. On first pair, surface a one-shot dialog deep-linking to system settings.

### Windows (slice 5.2)

- **System tray + close-to-tray.** Implemented via [`tray_manager`](https://pub.dev/packages/tray_manager) + `window_manager`. Closing the window hides it; only the tray menu's "Quit" actually exits the process.
- **No persistent notification.** Tray icon is the only ambient indicator. Toasts via [`flutter_local_notifications`](https://pub.dev/packages/flutter_local_notifications) fire on incoming transfer / pair invite and on completion.
- **Single-instance lock** so re-launching from Start Menu unhides the existing window instead of spawning a second one.

### iOS

Out of scope per [OQ-9](open-questions.md#oq-9). Plugins must initialize without crashing on iOS; no FG-equivalent functionality is wired. Foreground-only is the documented behavior.

### All platforms

- On an unrecognized network the watcher enters quiet mode — mDNS announcer off, HTTP server still up. Paired peers with cached IPs and pinned certs can still reach this device. See [security.md](security.md) for the full trust model.
- Pair-invite notifications are surfaced **only on trusted networks**, because [`/pair-invite`](#transport--strong-rules) is registered only on trusted networks and the route returns 404 otherwise. There is no "buffered invite" UX.

## Streaming and memory

Files are streamed end-to-end:

- Sender: `File.openRead()` → chunked HTTP upload.
- Receiver: shelf request body stream → `File.openWrite()`.

Never call `.readAsBytes()` on a payload. Test the design against a 4 GB file on a phone with 4 GB of RAM.

## Module boundaries (proposed `lib/` layout)

```text
lib/
  domain/
    entities/         peer.dart, transfer.dart, paired_device.dart
    repositories/     peer_discovery.dart (interface), transfer_service.dart (interface)
    usecases/         send_file.dart, receive_file.dart, pair_device.dart
  data/
    discovery/        mdns_peer_discovery.dart  (impl of PeerDiscovery via bonsoir)
    transport/        shelf_server.dart, http_client_transport.dart
    security/         psk_store.dart, hmac_signer.dart, tls_pin.dart
    storage/          downloads_path.dart, peer_cache.dart
  presentation/
    share/            share_intent_handler.dart, peer_picker_screen.dart
    pairing/          qr_pair_screen.dart
    transfers/        transfer_progress_screen.dart
    common/           theme.dart, animations.dart
  app/
    composition_root.dart, main.dart
```

This is a target, not a starting state — build it incrementally as each feature lands.
