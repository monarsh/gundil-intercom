// Minimal cross-platform audio I/O for the P2P intercom.
//
// Built on miniaudio, which picks the native backend at runtime:
//   Linux   -> PulseAudio / PipeWire-Pulse / ALSA
//   Windows -> WASAPI
//   Android -> AAudio / OpenSL ES
//
// Audio format is fixed to signed 16-bit mono PCM at the sample rate passed to
// ia_init(). Capture and playback each run on their own device with a lock-free
// single-producer/single-consumer ring buffer, so every call below is
// non-blocking and safe to make from the Dart main isolate.
#ifndef INTERCOM_AUDIO_H
#define INTERCOM_AUDIO_H

#include <stdint.h>

#if defined(_WIN32)
#define IA_EXPORT __declspec(dllexport)
#else
#define IA_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Initialises the audio context. Returns 0 on success.
IA_EXPORT int32_t ia_init(int32_t sample_rate);
IA_EXPORT void ia_shutdown(void);

IA_EXPORT int32_t ia_start_capture(void);
IA_EXPORT void ia_stop_capture(void);
IA_EXPORT int32_t ia_start_playback(void);
IA_EXPORT void ia_stop_playback(void);

// Copies up to max_frames captured samples into out. Returns frames copied.
IA_EXPORT int32_t ia_read_capture(int16_t* out, int32_t max_frames);
// Queues frames for playback. Returns frames accepted (may be < frames if full).
IA_EXPORT int32_t ia_write_playback(const int16_t* in, int32_t frames);
// Frames currently waiting in the playback queue.
IA_EXPORT int32_t ia_playback_queued(void);
// Drops everything waiting in the playback queue.
IA_EXPORT void ia_clear_playback(void);

// Human readable description of the last error (never NULL).
IA_EXPORT const char* ia_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
