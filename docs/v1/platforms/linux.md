# Linux — build, run, validate

Slice 5.x.5 phase 3 wired the .desktop entry, single-instance support,
and the AppImage packaging script. The existing LAN feature set works
on a Linux desktop with no Dart code changes.

## Build

```sh
flutter pub get
flutter config --enable-linux-desktop
flutter build linux --release
# Output: build/linux/x64/release/bundle/sharer
```

For development:

```sh
flutter run -d linux
```

## Build host requirements

Anything Flutter requires to build for Linux desktop, plus libsecret
for the AppImage step:

```sh
sudo apt-get install -y \
    ninja-build \
    libgtk-3-dev \
    libsecret-1-dev \
    libjsoncpp-dev \
    libayatana-appindicator3-dev
```

## Runtime requirements (host where the AppImage runs)

The AppImage bundles its own libsecret-1, so the only HOST requirement
is:

- **`avahi-daemon` running** — Bonsoir's Linux backend is an Avahi
  client. Without the daemon, mDNS browse silently returns no peers.
  Install + enable on Debian/Ubuntu:
  ```sh
  sudo apt-get install -y avahi-daemon
  sudo systemctl enable --now avahi-daemon
  ```
  Most modern desktops install Avahi by default. Server distros and
  some minimal installs don't.

## Build the AppImage

After `flutter build linux --release`:

```sh
./linux/packaging/build-appimage.sh
# Output: build/linux/x64/release/Sharer-x86_64.AppImage
```

The script:
1. Reorganises Flutter's bundle output into AppDir layout
   (`usr/bin/sharer`, `usr/lib/...`).
2. Drops the [`AppRun`](../../../linux/packaging/AppRun) launcher in
   place.
3. Copies [`linux/sharer.desktop`](../../../linux/sharer.desktop) into
   the AppDir root + `usr/share/applications/`.
4. Bundles libsecret-1 from the build host so the AppImage runs on
   distros that don't have it preinstalled.
5. Runs `appimagetool` to package + compress.

## What this slice covered

- [`linux/runner/my_application.cc`](../../../linux/runner/my_application.cc)
  — replaced flutter-create's `G_APPLICATION_NON_UNIQUE` with
  `G_APPLICATION_FLAGS_NONE` so GApplication's built-in D-Bus
  uniqueness kicks in. Tracks the main window in `main_window` so a
  second-process activation calls `gtk_window_present` instead of
  spawning a duplicate window. Equivalent to the Windows mutex from
  slice 5.x.3.4.
- [`linux/sharer.desktop`](../../../linux/sharer.desktop) — desktop
  entry with `Categories=Network;FileTransfer;`, used by file managers
  + the Activities/launcher overview.
- [`linux/packaging/AppRun`](../../../linux/packaging/AppRun) and
  [`linux/packaging/build-appimage.sh`](../../../linux/packaging/build-appimage.sh)
  — produce a portable AppImage.
- [`test/platform/linux_config_test.dart`](../../../test/platform/linux_config_test.dart)
  — 11 unit tests that parse .desktop, verify the single-instance flag
  is in `my_application.cc`, and check the packaging scripts reference
  the artifact names CI expects. Catches regressions on every CI run.

## Manual validation checklist (when Linux hardware is available)

1. **First launch** — `chmod +x Sharer-x86_64.AppImage && ./Sharer-x86_64.AppImage`.
   Look in stdout for the **boot canary** the existing `lib/main.dart`
   logs:
   ```
   [sharer.crypto] AES-GCM backend: FlutterAesGcm   ← good
   [sharer.crypto] AES-GCM backend: BackgroundAesGcm ← also good (separate-isolate)
   [sharer.crypto] AES-GCM backend: _DartAesGcm     ← BAD (pure Dart)
   ```
   `cryptography_flutter_plus` 3.x on Linux uses `BackgroundAesGcm`
   for inputs above an undocumented threshold. Our 64 KB chunks
   *should* qualify, but the canary is the only signal. If it shows
   `_DartAesGcm`, file an upstream issue and consider plan B (Android-
   only method-channel bridge to javax.crypto). Reference
   [reference_cryptography_flutter.md](../../security.md).
2. **Single-instance check** — launch the AppImage twice:
   ```sh
   ./Sharer-x86_64.AppImage &
   ./Sharer-x86_64.AppImage
   ```
   The second invocation should exit immediately (the call returns
   exit 0 without printing a second canary line) and the existing
   window should come to the foreground.
3. **Pair with Windows / Android** — `Devices → Pair`. Look for
   `[paired] paired device added: id=…` in logs.
4. **Send a small file** — pick a paired peer, drop a file. Verify
   it lands on the receiver. Log: `[sharer.transport.client] POST
   done bytesSent=…`.
5. **Send a 100 MB file** — re-baseline throughput. Expect
   ~25–40 MB/s on Wi-Fi 6, similar to Windows. Significant slowdown
   means the BackgroundAesGcm threshold isn't being hit — the canary
   line tells you.
6. **Receive a file** — verify it lands in `~/Downloads/` (Linux's
   XDG-defined Downloads dir via `path_provider.getDownloadsDirectory()`).
7. **Restart the AppImage** — paired devices should still be there.
   Tests `flutter_secure_storage`'s libsecret integration. If the
   pairing is gone, libsecret either isn't installed (host issue,
   shouldn't happen with the AppImage) or the host's libsecret is
   incompatible with the bundled one.
8. **AppImage on a clean distro** — bring up an Ubuntu / Fedora /
   Arch container without libsecret installed; verify the AppImage
   still launches because we bundled libsecret.

## Known limitations (alpha)

- **Unsigned AppImage**: no zsync URL, no GPG signature. Users have
  no automatic update path; they re-download manually for now.
- **No tray UX**: same scope-cut as macOS in phase 2. `tray_manager`
  + `libayatana-appindicator3` is a follow-up. For now the app sits
  in the taskbar like a normal GTK window.
- **No share-sheet**: Linux has no system-wide share mechanism. Nemo
  / Nautilus "Open with..." entries via the .desktop file is the
  closest analog; out of scope for v1.
- **Snap not supported**: snap's strict confinement blocks raw
  multicast (mDNS). Use the AppImage on snap-only distros.
- **Wayland**: should work via XWayland; native Wayland is whatever
  Flutter's Linux engine supports today (active development upstream).

## CI

[`.github/workflows/build-matrix.yml`](../../../.github/workflows/build-matrix.yml)
runs `flutter build linux --release --no-pub` on `ubuntu-latest`,
then runs `linux/packaging/build-appimage.sh` and uploads the
`Sharer-x86_64.AppImage` as a workflow artifact (14-day retention).
Catches dependency resolution + link errors without local Linux
hardware.

## Reference

- [AppImage docs](https://docs.appimage.org/)
- [Desktop Entry Spec](https://specifications.freedesktop.org/desktop-entry-spec/latest/)
- [GApplication uniqueness](https://docs.gtk.org/gio/class.Application.html#instances)
