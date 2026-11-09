#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "intercom_audio.h"

#include <stdio.h>
#include <string.h>

// One second of buffering in each direction is plenty; the Dart side keeps
// latency low by trimming the playback queue.
#define IA_RING_SECONDS 1

static ma_context g_context;
static int g_context_ready = 0;
static ma_uint32 g_sample_rate = 16000;

static ma_device g_capture;
static int g_capture_ready = 0;
static ma_pcm_rb g_capture_rb;

static ma_device g_playback;
static int g_playback_ready = 0;
static ma_pcm_rb g_playback_rb;
static volatile int g_clear_playback = 0;

static char g_error[256] = "";

static void set_error(const char* what, ma_result r) {
  snprintf(g_error, sizeof(g_error), "%s: %s", what, ma_result_description(r));
}

static void capture_cb(ma_device* dev, void* out, const void* in,
                       ma_uint32 frame_count) {
  (void)dev;
  (void)out;
  const ma_int16* src = (const ma_int16*)in;
  ma_uint32 remaining = frame_count;
  while (remaining > 0) {
    ma_uint32 n = remaining;
    void* dst;
    if (ma_pcm_rb_acquire_write(&g_capture_rb, &n, &dst) != MA_SUCCESS || n == 0)
      break;  // Consumer is behind: drop the rest of this block.
    memcpy(dst, src, n * sizeof(ma_int16));
    ma_pcm_rb_commit_write(&g_capture_rb, n);
    src += n;
    remaining -= n;
  }
}

static void playback_cb(ma_device* dev, void* out, const void* in,
                        ma_uint32 frame_count) {
  (void)dev;
  (void)in;
  ma_int16* dst = (ma_int16*)out;
  if (g_clear_playback) {
    // Consumer-side reset: skip everything currently readable.
    ma_uint32 avail = ma_pcm_rb_available_read(&g_playback_rb);
    ma_pcm_rb_seek_read(&g_playback_rb, avail);
    g_clear_playback = 0;
  }
  ma_uint32 remaining = frame_count;
  while (remaining > 0) {
    ma_uint32 n = remaining;
    void* src;
    if (ma_pcm_rb_acquire_read(&g_playback_rb, &n, &src) != MA_SUCCESS || n == 0)
      break;
    memcpy(dst, src, n * sizeof(ma_int16));
    ma_pcm_rb_commit_read(&g_playback_rb, n);
    dst += n;
    remaining -= n;
  }
  if (remaining > 0) memset(dst, 0, remaining * sizeof(ma_int16));  // underrun
}

int32_t ia_init(int32_t sample_rate) {
  if (g_context_ready) return 0;
  g_sample_rate = (ma_uint32)sample_rate;
  ma_result r = ma_context_init(NULL, 0, NULL, &g_context);
  if (r != MA_SUCCESS) {
    set_error("context init", r);
    return -1;
  }
  ma_uint32 cap = g_sample_rate * IA_RING_SECONDS;
  r = ma_pcm_rb_init(ma_format_s16, 1, cap, NULL, NULL, &g_capture_rb);
  if (r == MA_SUCCESS)
    r = ma_pcm_rb_init(ma_format_s16, 1, cap, NULL, NULL, &g_playback_rb);
  if (r != MA_SUCCESS) {
    set_error("ring buffer init", r);
    ma_context_uninit(&g_context);
    return -2;
  }
  g_context_ready = 1;
  return 0;
}

void ia_shutdown(void) {
  ia_stop_capture();
  ia_stop_playback();
  if (!g_context_ready) return;
  ma_pcm_rb_uninit(&g_capture_rb);
  ma_pcm_rb_uninit(&g_playback_rb);
  ma_context_uninit(&g_context);
  g_context_ready = 0;
}

int32_t ia_start_capture(void) {
  if (!g_context_ready) {
    snprintf(g_error, sizeof(g_error), "audio not initialised");
    return -1;
  }
  if (g_capture_ready) return 0;
  ma_pcm_rb_reset(&g_capture_rb);
  ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
  cfg.capture.format = ma_format_s16;
  cfg.capture.channels = 1;
  cfg.sampleRate = g_sample_rate;
  cfg.periodSizeInMilliseconds = 20;
  cfg.dataCallback = capture_cb;
#if defined(__ANDROID__)
  // Half-duplex push-to-talk: no echo canceller needed, just a clean mic.
  cfg.aaudio.inputPreset = ma_aaudio_input_preset_voice_recognition;
  cfg.opensl.recordingPreset = ma_opensl_recording_preset_voice_recognition;
#endif
  ma_result r = ma_device_init(&g_context, &cfg, &g_capture);
  if (r != MA_SUCCESS) {
    set_error("capture init", r);
    return -2;
  }
  r = ma_device_start(&g_capture);
  if (r != MA_SUCCESS) {
    set_error("capture start", r);
    ma_device_uninit(&g_capture);
    return -3;
  }
  g_capture_ready = 1;
  return 0;
}

void ia_stop_capture(void) {
  if (!g_capture_ready) return;
  ma_device_uninit(&g_capture);
  g_capture_ready = 0;
}

int32_t ia_start_playback(void) {
  if (!g_context_ready) {
    snprintf(g_error, sizeof(g_error), "audio not initialised");
    return -1;
  }
  if (g_playback_ready) return 0;
  ma_pcm_rb_reset(&g_playback_rb);
  g_clear_playback = 0;
  ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
  cfg.playback.format = ma_format_s16;
  cfg.playback.channels = 1;
  cfg.sampleRate = g_sample_rate;
  cfg.periodSizeInMilliseconds = 20;
  cfg.dataCallback = playback_cb;
#if defined(__ANDROID__)
  // Walkie-talkie: play loud through the loudspeaker (media path), not the
  // earpiece that the voice-call path would pick.
  cfg.aaudio.usage = ma_aaudio_usage_media;
  cfg.aaudio.contentType = ma_aaudio_content_type_speech;
  cfg.opensl.streamType = ma_opensl_stream_type_media;
#endif
  ma_result r = ma_device_init(&g_context, &cfg, &g_playback);
  if (r != MA_SUCCESS) {
    set_error("playback init", r);
    return -2;
  }
  r = ma_device_start(&g_playback);
  if (r != MA_SUCCESS) {
    set_error("playback start", r);
    ma_device_uninit(&g_playback);
    return -3;
  }
  g_playback_ready = 1;
  return 0;
}

void ia_stop_playback(void) {
  if (!g_playback_ready) return;
  ma_device_uninit(&g_playback);
  g_playback_ready = 0;
}

int32_t ia_read_capture(int16_t* out, int32_t max_frames) {
  if (!g_context_ready || max_frames <= 0) return 0;
  int32_t total = 0;
  while (total < max_frames) {
    ma_uint32 n = (ma_uint32)(max_frames - total);
    void* src;
    if (ma_pcm_rb_acquire_read(&g_capture_rb, &n, &src) != MA_SUCCESS || n == 0)
      break;
    memcpy(out + total, src, n * sizeof(int16_t));
    ma_pcm_rb_commit_read(&g_capture_rb, n);
    total += (int32_t)n;
  }
  return total;
}

int32_t ia_write_playback(const int16_t* in, int32_t frames) {
  if (!g_context_ready || frames <= 0) return 0;
  int32_t total = 0;
  while (total < frames) {
    ma_uint32 n = (ma_uint32)(frames - total);
    void* dst;
    if (ma_pcm_rb_acquire_write(&g_playback_rb, &n, &dst) != MA_SUCCESS || n == 0)
      break;
    memcpy(dst, in + total, n * sizeof(int16_t));
    ma_pcm_rb_commit_write(&g_playback_rb, n);
    total += (int32_t)n;
  }
  return total;
}

int32_t ia_playback_queued(void) {
  if (!g_context_ready) return 0;
  return (int32_t)ma_pcm_rb_available_read(&g_playback_rb);
}

void ia_clear_playback(void) { g_clear_playback = 1; }

const char* ia_last_error(void) { return g_error; }
