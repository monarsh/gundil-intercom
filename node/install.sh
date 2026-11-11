#!/usr/bin/env bash
# Installs the Gundil Intercom node as a service that starts on boot.
# Run from the unpacked folder:  sudo ./install.sh
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo: sudo ./install.sh" >&2; exit 1; fi
HERE="$(cd "$(dirname "$0")" && pwd)"

if command -v apt-get >/dev/null; then
  echo "==> Installing alsa-utils and gpiod (optional helpers)"
  apt-get install -y -qq alsa-utils gpiod >/dev/null 2>&1 || \
    echo "   (could not install; continuing)"
fi

echo "==> Copying to /opt/gundil-intercom"
mkdir -p /opt/gundil-intercom/lib
install -m 755 "$HERE/gundil-intercom-node" /opt/gundil-intercom/
install -m 644 "$HERE/lib/libintercom_audio.so" /opt/gundil-intercom/lib/
install -m 755 "$HERE/setup-audio.sh" /opt/gundil-intercom/

mkdir -p /etc/gundil-intercom
if [ ! -f /etc/gundil-intercom/node.conf ]; then
  # 600: it may hold the intercom password.
  install -m 600 "$HERE/node.conf.example" /etc/gundil-intercom/node.conf
  sed -i "s/^name = Gate$/name = $(hostname)/" /etc/gundil-intercom/node.conf
  if grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
    # Raspberry Pi: button on GPIO 17 (pin 11), LED on GPIO 27 (pin 13).
    sed -i 's/^button-gpio = 6$/button-gpio = 17/; s/^#led-gpio = 1$/#led-gpio = 27/' \
      /etc/gundil-intercom/node.conf
    echo "==> Raspberry Pi detected: button on GPIO 17 (pin 11)"
  fi
  echo "==> Created /etc/gundil-intercom/node.conf (edit it to taste)"
else
  echo "==> Keeping existing /etc/gundil-intercom/node.conf"
fi

echo "==> Setting up the audio codec"
/opt/gundil-intercom/setup-audio.sh || true

echo "==> Installing systemd service"
install -m 644 "$HERE/gundil-intercom-node.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable gundil-intercom-node >/dev/null
systemctl restart gundil-intercom-node

echo
echo "Done. Gundil Intercom node is running and starts on every boot."
echo "  Status / log:  systemctl status gundil-intercom-node"
echo "                 journalctl -u gundil-intercom-node -f"
echo "  Settings:      sudo nano /etc/gundil-intercom/node.conf"
echo "                 sudo systemctl restart gundil-intercom-node"
