Two-way (full-duplex) LAN intercom for **Android, Windows, Linux, Raspberry Pi and Orange Pi PC**.
Pick an intercom, press **Connect**, and both sides talk and listen at the same time until one hangs up.
During a call, Android and Windows can turn on their camera for video.
Intercoms find each other automatically on the same Wi-Fi/LAN. No server, no account.

## Which file do I need?

| Device | File |
|---|---|
| **Windows 10/11** | `GundilIntercom-VERSION-windows-x64-setup.exe` (installer). Portable alternative: `…-windows-x64-portable.zip` |
| **Android** phone/tablet | `GundilIntercom-VERSION-android-arm64-v8a.apk` (most phones). If unsure: `…-android-universal.apk` |
| **Linux PC** (x86_64) | `GundilIntercom-VERSION-x86_64.AppImage` (`chmod +x` it and run). Or `…-linux-x64.tar.gz` |
| **Raspberry Pi 4/5** with desktop, 64-bit OS | `GundilIntercom-VERSION-aarch64.AppImage`. Or `…-linux-arm64.tar.gz` |
| **Orange Pi PC**, Raspberry Pi with 32-bit OS, no screen | `gundil-intercom-node-VERSION-linux-arm.tar.gz` (headless node, see below) |
| Raspberry Pi / Orange Pi with 64-bit OS, no screen | `gundil-intercom-node-VERSION-linux-arm64.tar.gz` |

`SHA256SUMS.txt` lists checksums for every file.

## Install notes

- **Windows:** SmartScreen may warn about an unknown publisher (the installer isn't code-signed). Choose *More info → Run anyway*. The installer adds the firewall rule, a Start-menu entry and optional autostart. The app keeps running in the system tray.
- **Android:** allow *Install unknown apps*. The APKs are signed with a development key, which is fine for installing yourself, not for the Play Store. For always-on use, turn on *Settings → Run in background*.
- **Linux AppImage:** on Ubuntu 22.04+ you may need `sudo apt install libfuse2` (`libfuse2t64` on 24.04), or run it with `--appimage-extract-and-run`.
- **Orange Pi PC / Raspberry Pi node:** `tar xzf gundil-intercom-node-*.tar.gz`, `cd` into the folder, then `sudo ./install.sh`. It answers incoming connections automatically and connects with a GPIO button. Wiring and audio setup are in [node/README.md](https://github.com/monarsh/p2p-intercom/blob/vVERSION/node/README.md).
- **All devices need 1.0.0 or newer** (two-way audio). Older push-to-talk builds show as *Needs update* and can't connect.

## Network

Same LAN/Wi-Fi. Allow **TCP 47801** (audio and video) and **UDP 47800** (discovery). Audio is uncompressed 16 kHz mono, video is JPEG pictures, and neither is encrypted, so use it on trusted networks.
