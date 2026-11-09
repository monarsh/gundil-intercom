#!/usr/bin/env bash
# Builds the headless Gundil Intercom node for Linux and packages it.
#
#   tool/build_node.sh arm     # 32-bit ARM (Orange Pi PC/One/Zero, Pi 2/3 32-bit)
#   tool/build_node.sh arm64   # 64-bit ARM (Orange Pi 3/4/5, Pi 3/4/5 64-bit)
#   tool/build_node.sh x64     # PCs
#
# Needs the Dart SDK (Flutter's is fine) and a C cross-compiler. Preferred is
# Zig (pip install ziglang), which targets glibc 2.17 so the result runs on
# any distro from the last decade (Armbian Bullseye, Buster, ...). Fallback:
#   apt install gcc-arm-linux-gnueabihf gcc-aarch64-linux-gnu
# Output: build/node/gundil-intercom-node-linux-<arch>.tar.gz
set -euo pipefail

ARCH="${1:-arm}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$ARCH" in
  arm)   ZIG_TARGET="arm-linux-gnueabihf.2.17 -mcpu=cortex_a7"
         GCC="arm-linux-gnueabihf-gcc"; GCC_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard" ;;
  arm64) ZIG_TARGET="aarch64-linux-gnu.2.17"
         GCC="aarch64-linux-gnu-gcc";   GCC_FLAGS="" ;;
  x64)   ZIG_TARGET="x86_64-linux-gnu.2.17"
         GCC="gcc";                     GCC_FLAGS="" ;;
  *) echo "unknown arch: $ARCH (arm, arm64, x64)" >&2; exit 2 ;;
esac

if [ -n "${CC:-}" ]; then
  CC_CMD="$CC $GCC_FLAGS"
elif command -v zig >/dev/null; then
  CC_CMD="zig cc -target $ZIG_TARGET"
elif python3 -c 'import ziglang' 2>/dev/null; then
  CC_CMD="python3 -m ziglang cc -target $ZIG_TARGET"
else
  echo "warning: zig not found, using $GCC (needs the target's glibc to be as new as yours)" >&2
  CC_CMD="$GCC $GCC_FLAGS"
fi

NAME="gundil-intercom-node-linux-$ARCH"
OUT="$ROOT/build/node/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/lib"

echo "==> Dart executable ($ARCH)"
(cd "$ROOT/packages/intercom_core" && dart pub get >/dev/null &&
  dart compile exe bin/gundil_node.dart \
    --target-os linux --target-arch "$ARCH" \
    -o "$OUT/gundil-intercom-node")

echo "==> Native audio library ($CC_CMD)"
# shellcheck disable=SC2086
$CC_CMD -O2 -s -fPIC -shared -fvisibility=hidden \
  -o "$OUT/lib/libintercom_audio.so" \
  "$ROOT/packages/intercom_audio/src/intercom_audio.c" \
  -lpthread -lm -ldl

echo "==> Support files"
cp "$ROOT"/node/install.sh "$ROOT"/node/setup-audio.sh \
   "$ROOT"/node/node.conf.example "$ROOT"/node/gundil-intercom-node.service \
   "$ROOT"/node/README.md "$OUT/"
chmod +x "$OUT/install.sh" "$OUT/setup-audio.sh" "$OUT/gundil-intercom-node"

tar -C "$ROOT/build/node" -czf "$ROOT/build/node/$NAME.tar.gz" "$NAME"
echo "==> $ROOT/build/node/$NAME.tar.gz"
