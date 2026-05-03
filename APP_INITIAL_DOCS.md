# Local Network File Sharing App — Initial Documentation

> Historical note (2026-05-03): this document is the original architecture brainstorm, preserved for context. Several decisions here have since been superseded — most notably the SSID-based kill-switch, which has been replaced with a pairing-based trust model where the network watcher only suppresses mDNS announcements (the HTTP server stays up). For the current authoritative spec, see [docs/v1/](docs/v1/). When this file conflicts with `docs/v1/`, `docs/v1/` wins.

## Problem

Sharing files between personal devices (PC, Tablet, Phone) currently requires uploading to Google Drive or sending via WhatsApp and downloading on the other device. The goal is a self-hosted, local network solution that removes this dependency.

---

## Tech Stack Decision

**Chosen framework: Flutter**

Reasons:
- More mature Android support compared to Tauri 2.0
- `shelf` package enables an HTTP server in Dart
- `file_picker` handles file selection cleanly
- Tauri 2.0 was evaluated but its Android support still has rough edges, despite being promising for Windows

---

## Architecture

### P2P Mesh (no central server)

Every device runs simultaneously as a server and a client. There is no single point of failure — if one device is off, the remaining devices still communicate directly with each other.

```
💻 PC                    📱 Phone                 📟 Tablet
┌─────────────┐         ┌─────────────┐          ┌─────────────┐
│ HTTP Server │◄────────│ HTTP Client │          │ HTTP Server │
│ HTTP Client │         │ HTTP Server │◄─────────│ HTTP Client │
│ mDNS disco  │◄────────│ mDNS disco  │─────────►│ mDNS disco  │
└─────────────┘         └─────────────┘          └─────────────┘
      ▲                                                  │
      └──────────────────────────────────────────────────┘
```

### What each device runs

```
Each device runs:
├── HTTP Server (port 8080)    — receives files from peers
├── mDNS Announcer             — broadcasts presence every 2s
├── mDNS Listener              — discovers peers, maintains peer list
├── Network Watcher            — monitors SSID/subnet, kills app if outside trusted network
└── HTTP Client                — sends files to any peer's server
```

---

## Device Discovery

Devices use **mDNS** (multicast DNS) over the local network multicast address `224.0.0.251`.

Flow:
```
Device joins network
       │
       ▼
Announce via mDNS: "I'm [DeviceName] at 192.168.1.X:8080"
       │
       ▼
Listen for other mDNS announcements → build peer list
       │
       ▼
Each peer is now both a potential sender and receiver
```

When a device goes offline or closes the app, it stops announcing and disappears from peers' lists after the TTL expires.

**Flutter package:** `multicast_dns`

---

## Transfer Protocol

Simple REST API over HTTP. Endpoints:

- `POST /upload` — send a file to a peer
- `GET /files/:id` — retrieve a file from a peer

Chunked transfer is recommended for large files.

---

## LAN Security Kill Switch

The app monitors the network at regular intervals (~5 seconds). If the device leaves the trusted network, the app shuts down all activity.

### What is monitored
- Current Wi-Fi **SSID** — must match the trusted SSID recorded at first setup
- Current **IP subnet** — must remain within the trusted subnet (e.g. `192.168.1.x`)

### Logic
```
On app start → record trusted SSID (e.g. "MyHomeWifi")
               record trusted subnet (e.g. 192.168.1.x)

Every ~5 seconds:
  current SSID == trusted SSID?
  AND current IP in trusted subnet?
  → YES: keep running normally
  → NO:  stop HTTP server
          stop mDNS announcements
          clear peer list
          show "Outside trusted network" warning
```

### Flutter packages
- `connectivity_plus` — monitors connectivity changes
- `network_info_plus` — reads current SSID and IP

### Android note
Reading the SSID on Android 8+ requires the `ACCESS_FINE_LOCATION` permission.

---

## Security Considerations

| Measure | Notes |
|---|---|
| SSID check | Simple but not cryptographically secure — someone could spoof the SSID name |
| Subnet check | Adds a second layer on top of SSID alone |
| Shared secret key | A password agreed upon at setup time, used to sign requests — prevents communication even if SSID is spoofed |
| Encrypted transfer | Self-signed certificate per device enables HTTPS |

For personal use, SSID + subnet check is considered sufficient. The shared secret and HTTPS layers are optional hardening steps.

---

## LAN Requirements

- All devices must be on the **same Wi-Fi network**
- No router configuration or port forwarding required
- On Windows, a firewall dialog will appear on first run asking to allow the app through — the user accepts it once
- Android permissions required: `INTERNET`, `ACCESS_WIFI_STATE`, `ACCESS_FINE_LOCATION`

---

## Reference

**LocalSend** is an open-source Flutter app that follows the same P2P architecture described here and is a recommended reference for implementation.
