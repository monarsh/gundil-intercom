# Gundil Intercom

A serverless, peer-to-peer **push-to-talk intercom over TCP/IP** for **Linux,
Windows and Android**. It works like a walkie-talkie: pick who to talk to, hold
the button and talk. They hear you straight away. There's no dialling, no
answering and no chat. It's audio only.

![Desktop window transmitting to "Reception"; phone-sized window receiving](docs/screenshot.png)

## Features

- **Push-to-talk**: hold the big button (or the **Space bar** on desktop) to
  transmit. Let go to stop. The other side plays your voice immediately.
- **Switch channels with one tap**: talk to **Everyone** at once, or to a single
  peer. Tapping another entry in the list changes who you're talking to.
- **Zero configuration**: intercoms on the same LAN/Wi-Fi find each other
  automatically with UDP broadcast. No server and no accounts.
- **Clear "who's talking" indicator**: a speaker icon next to the peer, and a
  banner showing "*Office-PC is talking*".
- **Half-duplex like a real radio**: only one person is heard at a time.
  Incoming audio is muted while you're transmitting, so there's no feedback.
- **Roger beep**: a short chirp when the other side lets go.
- **Starts with Windows (or Linux login)**: optional. The app opens minimized
  at sign-in, so the intercom is always ready to receive.
- **Saved peers**: add a peer by IP (or keep a discovered one) and it stays in
  the list across restarts, greyed out while offline. The app keeps retrying
  in the background, so a saved peer comes online automatically. This also
  works on networks that block broadcast.
- **Edit peers**: every peer has a ⋮ menu (or long-press) to rename it, change
  its IP/port, keep it in the list, or remove it. If a saved device gets a new
  IP, the saved address updates itself once the device is seen again.

## How it works

```
 ┌──────────── Device A ────────────┐            ┌──────────── Device B ────────────┐
 │ Flutter UI (lib/ui)              │            │                                  │
 │   │                              │  UDP 47800 │                                  │
 │ IntercomService ── Discovery ────┼─ broadcast ┼──── Discovery                    │
 │   │      │                       │   beacons  │                                  │
 │   │   PeerConnection ────────────┼─ TCP 47801 ┼──── PeerConnection               │
 │   │      (framed protocol)       │            │                                  │
 │ AudioEngine ─ FFI ─ intercom_audio (C, miniaudio)                                │
 │   PulseAudio/ALSA · WASAPI · AAudio/OpenSL ES                                    │
 └──────────────────────────────────┘            └──────────────────────────────────┘
```

| Layer | File | Notes |
|---|---|---|
| Discovery | `lib/src/discovery.dart` | JSON beacon every 2 s to `255.255.255.255` and each interface's /24 broadcast address. A peer counts as offline after 7 s without a beacon. |
| Transport | `lib/src/peer_connection.dart` | One persistent TCP socket per peer pair, `TCP_NODELAY`. |
| Protocol | `lib/src/protocol.dart` | Each frame is `[type:1][length:4 BE][payload]`. |
| Push-to-talk logic | `lib/src/intercom_service.dart` | Peers, channel selection, transmit and receive. |
| Audio | `packages/intercom_audio` | Flutter FFI plugin built on [miniaudio](https://miniaud.io), with lock-free ring buffers between the native audio threads and Dart. The mic is open only while you hold the button. |
| Android glue | `android/.../MainActivity.kt` | Mic permission and the Wi-Fi multicast lock (needed to receive discovery broadcasts). |

### Wire protocol (v2)

| Code | Type | Payload |
|---|---|---|
| `0x01` | HELLO | `{"id","name","platform","port","v"}` (sent by both sides when the connection opens) |
| `0x02` | TALK_START | `{"sampleRate":16000,"group":bool}` (button pressed) |
| `0x03` | TALK_END | – (button released) |
| `0x04` | AUDIO | PCM16 little-endian, mono, 16 kHz, about every 20 ms |
| `0x08/0x09` | PING / PONG | – |

The receiver plays the first talker it hears. Anyone else who presses their
button at the same time is ignored until that talker lets go. A talker that
goes silent for 2 s (crash or lost network) is dropped automatically.

## Building

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(stable, 3.32 or newer). The audio library is vendored, so it needs no extra
packages.

```bash
flutter pub get
flutter test                      # unit + end-to-end (localhost TCP) tests
```

**Linux** (needs `clang cmake ninja-build pkg-config libgtk-3-dev`):

```bash
flutter build linux --release
./build/linux/x64/release/bundle/gundil_intercom
```

**Windows** (needs Visual Studio 2022 with "Desktop development with C++"):

```powershell
flutter build windows --release
build\windows\x64\runner\Release\gundil_intercom.exe
```

To build the installer (`setup.exe`) as well, install
[Inno Setup 6](https://jrsoftware.org/isinfo.php) and run:

```powershell
iscc /DMyAppVersion=1.0.0 installer\windows\gundil_intercom.iss
# -> build\installer\gundil-intercom-setup-1.0.0.exe
```

The installer puts the app in Program Files, adds a Start-menu shortcut (a
desktop shortcut is optional) and a Windows Firewall rule for the intercom's
ports, and registers a normal uninstaller. CI copies the Visual C++ runtime
DLLs into the bundle, so the app also runs on a fresh Windows install.

**Android** (needs the Android SDK with the NDK; minSdk 24):

```bash
flutter build apk --release --split-per-abi
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Every push runs `.github/workflows/build.yml`, which tests the code and uploads
these artifacts: a Linux tarball, the Windows installer
(`gundil-intercom-windows-setup`), a portable Windows folder, and Android APKs.

## Usage

1. Start the app on two or more devices on the **same LAN or Wi-Fi**. They
   appear in each other's list within about 2 seconds.
2. Choose **Everyone** or one peer in the list.
3. **Hold PUSH TO TALK** (or Space) and speak. Release when you're done. The
   button turns red and says **ON AIR** while you're transmitting.
4. When someone talks to you, their voice plays on your speaker and their name
   is highlighted.
5. If a peer doesn't appear, press **+ Add** (or the 🔗 icon) and enter the IP
   address shown in that device's *Settings*. A peer you add stays in the list
   until you remove it, even after the app restarts.
6. Use a peer's **⋮** menu to **Edit** it (name, IP, port), **Rename** a
   discovered peer, **Keep in list**, or **Remove** it.

### Start automatically

- **Windows**: tick *"Start Gundil Intercom automatically when I sign in"* in
  the installer, or turn on **Settings → Start with Windows** in the app
  later. It starts minimized in the taskbar. (This uses the per-user
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry. You can also
  turn it off in Task Manager → *Startup apps*.)
- **Linux**: **Settings → Start automatically at login** creates
  `~/.config/autostart/gundil-intercom.desktop`.
- **Android**: not supported. Android doesn't let apps start themselves after
  boot without a background service. Open the app once after the phone
  restarts.

Without the installer, you can do it by hand on Windows: press **Win+R**, type
`shell:startup`, and put a shortcut to `gundil_intercom.exe` in that folder.
Add `--minimized` to the shortcut's target if you want it to start minimized.

Set `P2P_INTERCOM_PROFILE=<name>` to run several separate instances on the same
computer, for example while testing.

### Firewall and network notes

- Allow **TCP 47801** (audio) and **UDP 47800** (discovery). Windows asks the
  first time you run the app. Allow *Private networks*.
- Guest Wi-Fi with "client isolation" blocks traffic between devices.
- If port 47801 is already taken, the app uses a random port and advertises it
  in its beacons.
- Audio is uncompressed (about 256 kbit/s while talking) and **not encrypted**.
  It is meant for trusted local networks.

## Project layout

```
lib/
  main.dart                 app entry, theme
  src/                      networking, protocol, push-to-talk logic (no UI)
  ui/                       home page, channel list, push-to-talk panel
packages/intercom_audio/    FFI audio plugin (C + miniaudio)
android/ linux/ windows/    platform runners
test/                       protocol + multi-node integration tests
```

## License

MIT. miniaudio is public domain / MIT-0.
