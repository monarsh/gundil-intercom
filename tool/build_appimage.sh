#!/usr/bin/env bash
# Packages the Linux desktop app as a single-file AppImage.
#
#   flutter build linux --release
#   tool/build_appimage.sh               # -> build/GundilIntercom-<ver>-<arch>.AppImage
#   tool/build_appimage.sh --appdir-only # only assemble build/appimage/GundilIntercom.AppDir
#
# Works for x86_64 and aarch64 (Raspberry Pi 4/5, 64-bit OS). Downloads
# appimagetool on first use (set APPIMAGETOOL=/path/to/appimagetool to use
# your own). The AppImage uses the system's GTK 3 (present on practically
# every Linux desktop) and its sound system (PipeWire, PulseAudio or ALSA).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR_ONLY=0
[ "${1:-}" = "--appdir-only" ] && APPDIR_ONLY=1

case "$(uname -m)" in
  x86_64)        ARCH=x86_64;  FLUTTER_ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64; FLUTTER_ARCH=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac

BUNDLE="$ROOT/build/linux/$FLUTTER_ARCH/release/bundle"
if [ ! -x "$BUNDLE/gundil_intercom" ]; then
  echo "Build the app first: flutter build linux --release" >&2
  exit 1
fi
VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$ROOT/pubspec.yaml")"

APPDIR="$ROOT/build/appimage/GundilIntercom.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# The Flutter bundle finds its libraries via $ORIGIN/lib, so copy it as is.
cp -a "$BUNDLE/." "$APPDIR/"
cp "$ROOT/linux/packaging/gundil-intercom.desktop" "$APPDIR/"
cp "$ROOT/linux/packaging/gundil-intercom.desktop" "$APPDIR/usr/share/applications/"
cp "$ROOT/linux/packaging/gundil-intercom.png" "$APPDIR/"
cp "$ROOT/linux/packaging/gundil-intercom.png" \
   "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
ln -sf gundil-intercom.png "$APPDIR/.DirIcon"

cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/gundil_intercom" "$@"
RUN
chmod +x "$APPDIR/AppRun"
echo "==> AppDir: $APPDIR"
[ "$APPDIR_ONLY" = 1 ] && exit 0

TOOL="${APPIMAGETOOL:-$ROOT/build/appimage/appimagetool-$ARCH.AppImage}"
if [ ! -x "$TOOL" ]; then
  echo "==> Downloading appimagetool ($ARCH)"
  curl -fsSL -o "$TOOL" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
  chmod +x "$TOOL"
fi

OUT="$ROOT/build/GundilIntercom-$VERSION-$ARCH.AppImage"
# APPIMAGE_EXTRACT_AND_RUN: works without FUSE (CI, containers).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$TOOL" --no-appstream "$APPDIR" "$OUT"
echo "==> $OUT"
