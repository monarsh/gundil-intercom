#!/usr/bin/env bash
# Sets up audio for the Gundil Intercom node on single-board computers.
#
#   sudo ./setup-audio.sh                 pick cards, set mixer levels
#   sudo ./setup-audio.sh --test          ...then record 3 s and play it back
#   sudo ./setup-audio.sh --playback 0 --capture 1   choose cards yourself
#
# Typical setups it handles:
#   * Orange Pi PC / One / Zero (Allwinner H3/H2+): on-board codec = speaker
#     jack + built-in microphone (same card).
#   * Raspberry Pi 3/4: headphone jack for the speaker + a USB microphone or
#     USB sound card for the mic (two different cards).
#   * Raspberry Pi 5 / any board: a USB sound card or USB speakerphone.
#
# Without PulseAudio/PipeWire (Lite / headless images) it writes
# /etc/asound.conf so the default ALSA device plays on the chosen speaker
# card and records from the chosen microphone card. Mixer control names
# differ between kernels; every mixer step is best effort. If something is
# silent, run `alsamixer` (F6 = choose card, F4 = capture), then
# `sudo alsactl store`.
set -u

PLAY="" CAP="" TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --playback) PLAY="$2"; shift ;;
    --capture)  CAP="$2"; shift ;;
    --test)     TEST=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# "card N: ID [Name], device ..." lines -> "N Name"
cards_of() { "$1" -l 2>/dev/null | sed -n 's/^card \([0-9]*\): [^[]*\[\([^]]*\)\].*/\1 \2/p' | sort -u; }

pick() {  # $1 = list of "N Name", $2.. = preferred name patterns in order
  local list="$1"; shift
  for pat in "$@"; do
    local n
    n=$(printf '%s\n' "$list" | grep -iE "$pat" | grep -viE 'hdmi' | head -1 | cut -d' ' -f1)
    if [ -n "$n" ]; then echo "$n"; return; fi
  done
  printf '%s\n' "$list" | grep -viE 'hdmi' | head -1 | cut -d' ' -f1
}

PLAY_CARDS=$(cards_of aplay)
CAP_CARDS=$(cards_of arecord)
if [ -z "$CAP_CARDS" ]; then
  echo "WARNING: no microphone found (arecord -l is empty)."
  echo "         Raspberry Pi has no built-in mic: plug in a USB microphone"
  echo "         or USB sound card, then run this script again."
fi

# Speaker: on-board codec / Pi headphone jack / USB audio.
PLAY="${PLAY:-$(pick "$PLAY_CARDS" 'codec|audiocodec|H3|sun[48]i' 'headphones|bcm2835' 'usb|speaker|phone' '.')}"
# Mic: on-board codec (Orange Pi built-in mic) / USB.
CAP="${CAP:-$(pick "$CAP_CARDS" 'codec|audiocodec|H3|sun[48]i' 'usb|mic|phone' '.')}"

echo "Speaker card: ${PLAY:-none}  ($(printf '%s\n' "$PLAY_CARDS" | sed -n "s/^$PLAY //p"))"
echo "Mic card:     ${CAP:-none}  ($(printf '%s\n' "$CAP_CARDS" | sed -n "s/^$CAP //p"))"

set_ctl() {  # card name value...
  local card="$1"; shift
  amixer -q -c "$card" sset "$@" 2>/dev/null && echo "  card $card: $*"
}

if [ -n "$PLAY" ]; then
  # Allwinner codec (Orange Pi)
  set_ctl "$PLAY" 'Line Out' 90% unmute
  set_ctl "$PLAY" 'DAC' 90% unmute
  # Raspberry Pi headphone jack / generic / USB
  set_ctl "$PLAY" 'Headphone' 90% unmute
  set_ctl "$PLAY" 'Master' 90% unmute
  set_ctl "$PLAY" 'PCM' 90% unmute
  set_ctl "$PLAY" 'Speaker' 90% unmute
fi
if [ -n "$CAP" ]; then
  # Allwinner codec: built-in mic is on MIC1
  set_ctl "$CAP" 'Mic1' cap
  set_ctl "$CAP" 'Mic1' 70% unmute
  set_ctl "$CAP" 'Mic1 Boost' 50%
  set_ctl "$CAP" 'ADC Gain' 50%
  set_ctl "$CAP" 'ADC' 80%
  # USB microphones / sound cards
  set_ctl "$CAP" 'Mic' 80% cap unmute
  set_ctl "$CAP" 'Capture' 80% cap
  set_ctl "$CAP" 'Auto Gain Control' off
fi

if pgrep -x pulseaudio >/dev/null || pgrep -x pipewire >/dev/null; then
  echo "PulseAudio/PipeWire is running: choose the speaker and mic in its"
  echo "settings (e.g. pavucontrol, or the desktop's sound settings)."
elif [ -n "$PLAY" ] && [ -n "$CAP" ]; then
  if [ -e /etc/asound.conf ] && ! grep -q 'Gundil Intercom' /etc/asound.conf; then
    echo "Keeping your existing /etc/asound.conf"
  else
    cat > /etc/asound.conf <<EOF
# Written by Gundil Intercom setup-audio.sh
# Default device: speaker on card $PLAY, microphone on card $CAP.
pcm.!default {
  type asym
  playback.pcm "plughw:$PLAY"
  capture.pcm "plughw:$CAP"
}
ctl.!default {
  type hw
  card $PLAY
}
EOF
    echo "  wrote /etc/asound.conf (speaker card $PLAY, mic card $CAP)"
  fi
fi

alsactl store 2>/dev/null && echo "  saved mixer settings"

if [ "$TEST" = 1 ] && [ -n "$CAP" ] && [ -n "$PLAY" ]; then
  echo "Recording 3 seconds — say something..."
  arecord -q -D "plughw:$CAP" -f S16_LE -r 16000 -c 1 -d 3 /tmp/gundil-test.wav
  echo "Playing it back..."
  aplay -q -D "plughw:$PLAY" /tmp/gundil-test.wav
fi
