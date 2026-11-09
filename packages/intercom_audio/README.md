# intercom_audio

Flutter FFI plugin providing low-latency 16-bit mono PCM microphone capture and
speaker playback on **Linux, Windows and Android** using
[miniaudio](https://miniaud.io) (vendored as `src/miniaudio.h`, public domain /
MIT-0).

Backends are selected at runtime: PulseAudio/PipeWire/ALSA on Linux, WASAPI on
Windows, AAudio/OpenSL ES on Android. No extra system packages are needed to
build.
