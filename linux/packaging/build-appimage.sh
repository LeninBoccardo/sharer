#!/usr/bin/env bash
# Slice 5.x.5 phase 3 — build an AppImage from `flutter build linux`
# output. Runs in CI on ubuntu-latest; can also be run locally on any
# Linux box.
#
# Inputs:
#   - build/linux/x64/release/bundle/  (must exist; produced by
#                                        `flutter build linux --release`)
#   - linux/sharer.desktop
#   - linux/packaging/AppRun
#   - data/flutter_assets/.../icon (best-effort)
#
# Output:
#   - build/linux/x64/release/Sharer-x86_64.AppImage
#
# Runtime requirements bundled INTO the AppImage:
#   - libsecret-1-0 (for flutter_secure_storage)
# Runtime requirements that must be on the HOST (cannot be bundled):
#   - avahi-daemon running (for Bonsoir mDNS browse)
#   - DBus (universally present)

set -euo pipefail

cd "$(dirname -- "$0")/../.."  # repo root

if [ ! -d build/linux/x64/release/bundle ]; then
  echo "ERROR: flutter build linux --release must run before this script" >&2
  exit 1
fi

APP_DIR="build/linux/x64/release/Sharer.AppDir"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/usr/bin" \
         "$APP_DIR/usr/lib" \
         "$APP_DIR/usr/share/applications" \
         "$APP_DIR/usr/share/icons/hicolor/256x256/apps"

# 1. Copy the Flutter bundle into usr/bin + usr/lib structure
cp -r build/linux/x64/release/bundle/* "$APP_DIR/usr/"
# Flutter's bundle has the exec at bundle/sharer + libs at bundle/lib/.
# Reorganise to FHS-ish layout: bin/sharer, lib/<libs>.
mv "$APP_DIR/usr/sharer" "$APP_DIR/usr/bin/sharer"
if [ -d "$APP_DIR/usr/lib" ]; then
  : # already there from copy
fi

# 2. AppRun launcher
install -m 0755 linux/packaging/AppRun "$APP_DIR/AppRun"

# 3. .desktop file at AppDir root + standard location
cp linux/sharer.desktop "$APP_DIR/sharer.desktop"
cp linux/sharer.desktop "$APP_DIR/usr/share/applications/sharer.desktop"

# 4. Icon at AppDir root + hicolor theme
# Best-effort: pull a launcher icon from the assets bundle if present;
# otherwise emit a 1×1 PNG placeholder so AppImage tooling doesn't
# refuse to build. Replace once we have proper icon art.
ICON_SRC=""
if [ -f "assets/tray_icon.ico" ]; then
  if command -v magick >/dev/null 2>&1; then
    magick assets/tray_icon.ico -resize 256x256 "$APP_DIR/sharer.png"
    ICON_SRC="$APP_DIR/sharer.png"
  fi
fi
if [ -z "$ICON_SRC" ]; then
  # Pink-square placeholder — visible "this needs a real icon" tell.
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDAT\x08\x99c\xfc\xff\x9f\xe1?\x00\x07\x05\x03\x01\x9b\x9d\xb9\xa6\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$APP_DIR/sharer.png"
  ICON_SRC="$APP_DIR/sharer.png"
fi
cp "$ICON_SRC" "$APP_DIR/usr/share/icons/hicolor/256x256/apps/sharer.png"

# 5. Bundle libsecret-1 so the AppImage works on hosts that don't have
# it installed. Best-effort: copy the resolved .so files from the
# host. If a host doesn't even have libsecret installed, abort with a
# clear error rather than producing a broken AppImage.
if ! ldconfig -p | grep -q libsecret-1.so.0; then
  echo "ERROR: libsecret-1-0 is not installed on this build host. Install it" >&2
  echo "before running build-appimage.sh:" >&2
  echo "    sudo apt-get install -y libsecret-1-0 libsecret-1-dev" >&2
  exit 1
fi
LIBSECRET_PATH="$(ldconfig -p | awk '/libsecret-1.so.0/ { print $4; exit }')"
cp "$LIBSECRET_PATH" "$APP_DIR/usr/lib/"

# 6. Fetch appimagetool if not on PATH
if ! command -v appimagetool >/dev/null 2>&1; then
  curl -sSfL \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" \
    -o /tmp/appimagetool
  chmod +x /tmp/appimagetool
  APPIMAGETOOL=/tmp/appimagetool
else
  APPIMAGETOOL="$(command -v appimagetool)"
fi

# 7. Build. -n skips signing (we don't have a key in CI yet).
ARCH=x86_64 "$APPIMAGETOOL" -n "$APP_DIR" \
  "build/linux/x64/release/Sharer-x86_64.AppImage"

echo "AppImage built: build/linux/x64/release/Sharer-x86_64.AppImage"
ls -la "build/linux/x64/release/Sharer-x86_64.AppImage"
