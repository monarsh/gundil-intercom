# Gundil Intercom node: Orange Pi PC / single-board computers

A headless (no screen) Gundil Intercom for small Linux boards. It joins the
same network intercom as the phone and PC apps:

- appears in their lists automatically, and you can talk to it from them;
- plays incoming talk on the **speaker/headphone jack**;
- transmits from the **built-in microphone** while a **push-to-talk button**
  on the GPIO header is held (or a USB key/foot pedal);
- optional **LED** that lights while talking or receiving;
- starts automatically on boot.

Tested target: **Orange Pi PC** (Allwinner H3, 32-bit ARM) with Armbian
Bookworm or Jammy. Other H3/H2+/H5 Orange Pis and Raspberry Pis work the
same way; pick the matching download:

| Board | Download |
|---|---|
| Orange Pi PC / PC Plus / One / Lite / Zero (H3, H2+), Raspberry Pi 2/3 with 32-bit OS | `gundil-intercom-node-linux-arm.tar.gz` |
| Orange Pi PC 2, Zero 2, 3, 4, 5; Raspberry Pi 3/4/5 with 64-bit OS | `gundil-intercom-node-linux-arm64.tar.gz` |

(The desktop app with a window needs a 64-bit board. The Orange Pi PC is
32-bit, so it runs this headless node instead.)

## Install

On the Orange Pi (SSH in, or use a keyboard and screen once):

```bash
tar xzf gundil-intercom-node-linux-arm.tar.gz
cd gundil-intercom-node-linux-arm
sudo ./install.sh
```

The installer:

1. copies the program to `/opt/gundil-intercom`;
2. creates `/etc/gundil-intercom/node.conf`;
3. sets the mixer levels of the on-board audio (jack + built-in mic);
4. installs and starts the `gundil-intercom-node` service, which starts on
   every boot.

Check it:

```bash
journalctl -u gundil-intercom-node -f
```

You should see `Gundil Intercom node "orangepipc" listening ...` and the
other intercoms coming online. On your phone or PC the Orange Pi shows up in
the peer list. Hold push-to-talk there and you hear it from the speaker jack.

## Wiring the button and LED (Orange Pi PC)

```
  40-pin header (pin 1 is next to the SD card / marked with a triangle)

   3.3V  (1) (2)  5V
   PA12  (3) (4)  5V
   PA11  (5) (6)  GND
   PA6   (7) (8)  PA13       <- pin 7 = push-to-talk button (GPIO 6)
   GND   (9) (10) PA14       <- pin 9 = GND for button and LED
   PA1  (11) (12) PD14       <- pin 11 = LED via 330 Ω resistor (GPIO 1)
   PA0  (13) (14) GND
   PA3  (15) (16) PC4
   ...
```

- **Button**: one leg to **pin 7**, the other to **pin 9 (GND)**.
  `ptt-gpio = 6`, `ptt-gpio-active-low = true` (the defaults in
  `node.conf`). With the `gpiod` tools installed (the installer does this),
  the internal pull-up resistor is switched on, so no other parts are needed.
  Without them (sysfs mode), add a 10 kΩ resistor from pin 7 to pin 1 (3.3 V).
- **LED** (optional): **pin 11 → 330 Ω → LED anode (+)**, LED cathode (−) →
  **GND** (pin 9 or 14). Set `led-gpio = 1`.

GPIO numbers on Allwinner chips are `port × 32 + pin` (PA = 0, PC = 2,
PD = 3, PG = 6). Some other free pins on the Orange Pi PC:

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

## Settings

Edit `/etc/gundil-intercom/node.conf`, then
`sudo systemctl restart gundil-intercom-node`:

| Setting | Meaning |
|---|---|
| `name` | Name shown on the other intercoms |
| `target` | `everyone`, or the name of one intercom the button talks to |
| `ptt-gpio`, `ptt-gpio-active-low` | Push-to-talk button pin |
| `led-gpio` | Optional activity LED pin |
| `gpio-backend` | `auto`, `gpiod` or `sysfs` |
| `ptt-input`, `ptt-key` | Use a USB keyboard/foot pedal key instead of (or as well as) GPIO |
| `peers` | Intercoms to add by IP if discovery doesn't reach them |
| `roger-beep` | Beep when the other side lets go |

Run `/opt/gundil-intercom/gundil-intercom-node --help` for all options.

## Audio troubleshooting

- **Re-run the audio setup and test it**: `sudo /opt/gundil-intercom/setup-audio.sh --test`
  records 3 s from the built-in mic and plays it back on the jack.
- **Too quiet or too loud**: `alsamixer` → F6 to pick the *H3 Audio Codec*
  card, adjust *Line Out* / *DAC* (playback) and, under F4, *Mic1* /
  *Mic1 Boost* / *ADC Gain* (capture). Then run `sudo alsactl store`.
- **No sound at all**: list the cards with `aplay -l` and `arecord -l`. If the
  analog codec is not card 0, `setup-audio.sh` writes `/etc/asound.conf` to
  make it the default.
- The node has no echo cancellation. Keep the speaker away from the
  built-in mic. This is less of a problem than on a phone, because a
  walkie-talkie never plays and records at the same time.

## Try it by hand (without the service)

```bash
sudo systemctl stop gundil-intercom-node
sudo /opt/gundil-intercom/gundil-intercom-node --config=/etc/gundil-intercom/node.conf
```

In the terminal, press **Enter** to start or stop talking. `l` lists the
intercoms, `t Office-PC` chooses who to talk to, and `q` quits.

## Uninstall

```bash
sudo systemctl disable --now gundil-intercom-node
sudo rm -rf /opt/gundil-intercom /etc/gundil-intercom /var/lib/gundil-intercom \
  /etc/systemd/system/gundil-intercom-node.service
```
