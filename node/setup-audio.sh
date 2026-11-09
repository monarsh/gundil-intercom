#!/usr/bin/env bash
# Configures the on-board analog audio (speaker/headphone jack + built-in
# microphone) of Allwinner H3/H2+/H5 boards such as the Orange Pi PC.
#
#   sudo ./setup-audio.sh          set mixer levels and default card
#   sudo ./setup-audio.sh --test   also record 3 s from the mic and play it back
#
# Control names differ between kernels; every step is best effort. If
# something is still silent, run `alsamixer -c <card>` (F4 = capture view)
# and then `sudo alsactl store`.
set -u

card=""
# Prefer the analog codec over HDMI audio.
while read -r num rest; do
  case "$rest" in
    *[Cc]odec*|*audiocodec*|*H3*|*sun8i*|*sun4i*) card="$num"; break ;;
  esac
done < <(grep -E '^ *[0-9]+ ' /proc/asound/cards 2>/dev/null | sed 's/^ *//')
card="${card:-0}"
echo "Using sound card $card: $(sed -n "s/^ *$card \[\(.*\)\].*/\1/p" /proc/asound/cards 2>/dev/null)"

set_ctl() {  # name value...
  if amixer -q -c "$card" sset "$@" 2>/dev/null; then
    echo "  ok   $*"
  fi
}

# Playback: line out / headphone jack
set_ctl 'Line Out' 90% unmute
set_ctl 'Line Out Source' 'Mono Differential' 2>/dev/null || true
set_ctl 'DAC' 90% unmute
set_ctl 'Headphone' 90% unmute
set_ctl 'Master' 90% unmute
set_ctl 'PCM' 90% unmute
# Capture: built-in microphone on MIC1
set_ctl 'Mic1' cap
set_ctl 'Mic1' 70% unmute
set_ctl 'Mic1 Boost' 50%
set_ctl 'ADC Gain' 50%
set_ctl 'ADC' 80%
set_ctl 'Capture' 80% cap
set_ctl 'Mixer' cap 2>/dev/null || true

# Make the analog codec the default ALSA device (only when no PulseAudio /
# PipeWire and no existing config).
if [ "$card" != "0" ] && [ ! -e /etc/asound.conf ] && \
   ! pgrep -x pulseaudio >/dev/null && ! pgrep -x pipewire >/dev/null; then
  printf 'defaults.pcm.card %s\ndefaults.ctl.card %s\n' "$card" "$card" > /etc/asound.conf
  echo "  wrote /etc/asound.conf (default card $card)"
fi

alsactl store 2>/dev/null && echo "  saved mixer settings"

if [ "${1:-}" = "--test" ]; then
  echo "Recording 3 seconds — say something..."
  arecord -q -D "plughw:$card" -f S16_LE -r 16000 -c 1 -d 3 /tmp/gundil-test.wav
  echo "Playing it back..."
  aplay -q -D "plughw:$card" /tmp/gundil-test.wav
fi
