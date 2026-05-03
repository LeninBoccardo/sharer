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
                multicast_dns wrapper, secure storage, file system.
```

Dependencies point inward. `domain` imports nothing from `data` or `presentation` and contains no Flutter imports. Composition root (in `presentation` or a top-level `app/` module) wires concrete `data` implementations into the `domain` interfaces.

## Subsystems

Each subsystem is a separately testable module behind a `domain` interface.

| Subsystem | Always on? | Notes |
| --- | --- | --- |
| HTTP server (shelf) | Always on (any network) | Streams uploads to disk; never buffers full files. Port 8080 default, fall back if taken. Authenticated by HMAC + cert pinning, so it's safe to leave running on unfamiliar networks. |
| HTTP client | On demand | Streams from disk. Uses connection pooling for chunked transfers. |
| mDNS announcer (`_sharer._tcp`) | **Event driven, trusted networks only.** | Activates when share UI opens or app is foregrounded. **Suppressed entirely on unrecognized networks** (quiet mode). Stops after a quiet period. |
| mDNS listener | Passive, low-cost, always on | Maintains in-memory peer list with TTL expiry. Runs even on unrecognized networks so we still discover a paired peer that announces itself there. |
| Network watcher | Always on | Polls SSID + subnet every ~5 s. On unrecognized network, sets the announcer to quiet mode and surfaces a banner. **Does not stop the server.** Trust boundary is pairing, not network — see [security.md](security.md). |
| Peer cache | Persistent | Last-known peer IP + cert fingerprint per paired device, used for optimistic connect. Survives across networks so paired peers can be reached even when neither side is announcing. |

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

## Background behavior

- **Mobile:** no foreground service when idle. A foreground service starts only when an active transfer is in flight (Android requirement for sustained network work). The persistent notification disappears once transfers complete.
- **Desktop:** the app may run in the system tray. Idle cost is the cheap mDNS listener and the SSID poll.
- **All platforms:** on an unrecognized network, the watcher enters quiet mode — mDNS announcer off, HTTP server still up. Paired peers with cached IPs and pinned certs can still reach this device. See [security.md](security.md) for the full trust model.

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
    discovery/        mdns_peer_discovery.dart  (impl of PeerDiscovery)
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
