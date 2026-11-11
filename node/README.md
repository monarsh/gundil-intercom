# Gundil Intercom node: Orange Pi PC, Raspberry Pi and other boards

A headless (no screen) Gundil Intercom for small Linux boards. It joins the
same **two-way** intercom network as the Android, Windows and Linux apps:

- appears in their lists automatically;
- **answers incoming connections at once** (door-station behaviour). Both
  sides then talk and listen at the same time until one hangs up;
- a **button** on the GPIO header (or a USB key/foot pedal) connects to a
  chosen intercom or to everyone, and hangs up;
- optional **LED**: on while connected, blinking while calling or ringing;
- software **echo suppression**, so the other side doesn't hear itself from
  this board's speaker;
- starts automatically on boot.

| Board | Microphone | Speaker | Download |
|---|---|---|---|
| **Orange Pi PC** / PC Plus / One / Lite / Zero (H3, H2+) | built-in mic | 3.5 mm jack | `gundil-intercom-node-linux-arm.tar.gz` |
| **Raspberry Pi 3/4**, 32-bit Raspberry Pi OS | USB mic or USB sound card | 3.5 mm jack or USB | `gundil-intercom-node-linux-arm.tar.gz` |
| **Raspberry Pi 3/4/5**, 64-bit Raspberry Pi OS | USB mic or USB sound card | jack (3/4), USB, HDMI | `gundil-intercom-node-linux-arm64.tar.gz` |
| Orange Pi PC 2 / Zero 2 / 3 / 4 / 5 (64-bit) | board or USB | board or USB | `gundil-intercom-node-linux-arm64.tar.gz` |

A USB speakerphone (mic + speaker in one, with built-in echo cancelling) is
the easiest choice for a Raspberry Pi. On a Raspberry Pi 4/5 with the 64-bit
desktop you can also run the full app with a window
(`gundil-intercom-linux-arm64.tar.gz`). The node is for boards without a screen.

Not sure which download? Run `uname -m`: `armv7l` → `-arm`, `aarch64` → `-arm64`.

## Install

On the board (SSH in, or use a keyboard and screen once):

```bash
tar xzf gundil-intercom-node-linux-arm.tar.gz     # or -arm64
cd gundil-intercom-node-linux-arm
sudo ./install.sh
```

The installer:

1. installs `alsa-utils` and `gpiod`;
2. copies the program to `/opt/gundil-intercom`;
3. creates `/etc/gundil-intercom/node.conf`;
4. sets up audio. It picks the speaker card and the mic card (they can
   differ, for example Pi headphone jack + USB mic) and sets mixer levels;
5. installs and starts the `gundil-intercom-node` service, which starts on
   every boot.

Check it:

```bash
journalctl -u gundil-intercom-node -f
```

You should see `Gundil Intercom node "orangepipc" listening ...` and the
other intercoms coming online. On your phone or PC, select the board and
press **Connect**: the board answers, and you hear each other both ways.

## Wiring

### Orange Pi PC

```
  40-pin header (pin 1 is next to the SD card / marked with a triangle)

   3.3V  (1) (2)  5V
   PA12  (3) (4)  5V
   PA11  (5) (6)  GND
   PA6   (7) (8)  PA13       <- pin 7 = button (GPIO 6)
   GND   (9) (10) PA14       <- pin 9 = GND for button and LED
   PA1  (11) (12) PD14       <- pin 11 = LED via 330 Ω resistor (GPIO 1)
   PA0  (13) (14) GND
   PA3  (15) (16) PC4
   ...
```

- **Button**: between **pin 7** and **pin 9 (GND)**. Settings:
  `button-gpio = 6`, `button-gpio-active-low = true`.
- **LED** (optional): **pin 11 → 330 Ω → LED (+)**, LED (−) → **GND**.
  Setting: `led-gpio = 1`.

GPIO numbers on Allwinner chips are `port × 32 + pin` (PA = 0, PC = 2,
PD = 3, PG = 6). Other free pins on the Orange Pi PC:

| Physical pin | Pin name | GPIO number |
|---|---|---|
| 7 | PA6 | 6 |
| 11 | PA1 | 1 |
| 13 | PA0 | 0 |
| 15 | PA3 | 3 |
| 16 | PC4 | 68 |
| 18 | PC7 | 71 |
| 22 | PA2 | 2 |
| 29 | PA7 | 7 |
| 31 | PA8 | 8 |
| 33 | PA9 | 9 |
| 35 | PA10 | 10 |
| 37 | PA20 | 20 |

Check your board's pinout before wiring, because layouts differ between
models. `gpio readall` (WiringOP) prints the table for the board you have.

### Raspberry Pi (all models with the 40-pin header)

Use **BCM** GPIO numbers:

- **Button**: between **physical pin 11 (GPIO 17)** and **pin 9 (GND)**.
  Settings: `button-gpio = 17`, `button-gpio-active-low = true`.
- **LED** (optional): **physical pin 13 (GPIO 27) → 330 Ω → LED (+)**,
  LED (−) → **GND** (pin 14). Setting: `led-gpio = 27`.
- Keep `gpio-backend = auto` (uses the `gpiod` tools installed by
  `install.sh`). On current Raspberry Pi OS, `/sys/class/gpio` numbers are
  offset (GPIO 17 = 529), so the gpiod backend is the reliable choice. On a
  **Raspberry Pi 5** with an older kernel, set `gpio-chip = gpiochip4` if the
  button does nothing.

With the gpiod tools the internal pull-up resistor is switched on, so the
button needs no other parts. In sysfs mode (`gpio-backend = sysfs`), add a
10 kΩ resistor from the button pin to 3.3 V.

## Settings

Edit `/etc/gundil-intercom/node.conf`, then
`sudo systemctl restart gundil-intercom-node`:

| Setting | Meaning |
|---|---|
| `name` | Name shown on the other intercoms |
| `auto-answer` | `true` (default): open incoming connections at once. `false`: ring until the button is pressed |
| `target` | `everyone`, or the name of the intercom the button connects to |
| `button-gpio`, `button-gpio-active-low` | Button pin (press = connect / accept / hang up) |
| `led-gpio` | Optional LED pin |
| `speaker-volume`, `mic-volume` | Volume in percent, 0–200 (default 100). Above 100 boosts quiet audio |
| `echo-suppression` | Lower the mic while the other side talks (default `true`). Turn off with a headset or an echo-cancelling USB speakerphone |
| `gpio-backend`, `gpio-chip` | `auto` / `gpiod` / `sysfs`, and the gpiochip for gpiod |
| `button-input`, `button-key` | Use a USB keyboard/foot pedal key as the button |
| `password` | Intercom password. Calls are always encrypted; with a password only intercoms with the same password can connect. Set the same one on every device |
| `peers` | Intercoms to add by IP if discovery doesn't reach them |
| `tones` | Connect / hang-up / ring tones |

Settings from earlier versions (`ptt-gpio`, `ptt-input`, ...) still work.
Run `/opt/gundil-intercom/gundil-intercom-node --help` for all options.

## Audio troubleshooting

- **Re-run the audio setup and test it**:
  `sudo /opt/gundil-intercom/setup-audio.sh --test` records 3 s from the mic
  and plays it back on the speaker.
- **Wrong card picked**: `aplay -l` and `arecord -l` list the cards. Then
  choose them yourself, for example
  `sudo /opt/gundil-intercom/setup-audio.sh --playback 1 --capture 2`.
- **Too quiet or too loud**: `alsamixer` → F6 to pick the card, adjust the
  playback level, and under F4 the capture (mic) level. Then run
  `sudo alsactl store`. On the Orange Pi PC the controls are *Line Out* /
  *DAC* and *Mic1* / *Mic1 Boost* / *ADC Gain*.
- **The other side hears an echo**: move the speaker away from the mic, lower
  the speaker volume, or use a USB speakerphone with built-in echo
  cancellation (then set `echo-suppression = false`).
- **Raspberry Pi OS with desktop** runs PipeWire. Pick the speaker and mic in
  the desktop's sound settings instead of `setup-audio.sh`.

## Try it by hand (without the service)

```bash
sudo systemctl stop gundil-intercom-node
sudo /opt/gundil-intercom/gundil-intercom-node --config=/etc/gundil-intercom/node.conf
```

In the terminal:

| Key | Action |
|---|---|
| **Enter** | Connect / accept / hang up (same as the button) |
| `a` / `d` | Accept / decline a ringing call |
| `m` | Mute / unmute the microphone |
| `l` | List intercoms |
| `t Office-PC` | Choose who the button connects to |
| `q` | Quit |

## Uninstall

```bash
sudo systemctl disable --now gundil-intercom-node
sudo rm -rf /opt/gundil-intercom /etc/gundil-intercom /var/lib/gundil-intercom \
  /etc/systemd/system/gundil-intercom-node.service
```
