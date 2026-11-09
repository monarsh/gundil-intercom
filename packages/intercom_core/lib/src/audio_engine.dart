import 'dart:typed_data';

import 'native_audio_bindings.dart';

/// Abstraction over the microphone/speaker so the intercom logic can be tested
/// without real audio hardware. Capture and playback are independent because
/// a walkie-talkie only ever does one of them at a time.
abstract class AudioEngine {
  int get sampleRate;
  void init(int sampleRate);

  void startCapture();
  void stopCapture();
  void startPlayback();
  void stopPlayback();

  /// Returns all microphone samples captured since the last call.
  Int16List readCaptured();

  /// Queues samples for the speaker.
  void play(Int16List samples);

  /// Samples waiting to be played.
  int get queued;

  /// Drops queued playback (used to cap latency).
  void flushPlayback();
}

/// Real audio through the native `intercom_audio` FFI plugin.
class NativeAudioEngine implements AudioEngine {
  IntercomAudio get _a => IntercomAudio.instance;
  int _rate = 16000;

  @override
  int get sampleRate => _rate;

  @override
  void init(int sampleRate) {
    _rate = sampleRate;
    _a.init(sampleRate);
  }

  @override
  void startCapture() => _a.startCapture();
  @override
  void stopCapture() => _a.stopCapture();
  @override
  void startPlayback() => _a.startPlayback();
  @override
  void stopPlayback() => _a.stopPlayback();

  @override
  Int16List readCaptured() => _a.readCapture();

  @override
  void play(Int16List samples) => _a.writePlayback(samples);

  @override
  int get queued => _a.playbackQueued;

  @override
  void flushPlayback() => _a.clearPlayback();
}

/// Silent engine used in tests or when no audio device is available.
/// Captured audio can be injected with [inject]; played audio is collected in
/// [played].
class FakeAudioEngine implements AudioEngine {
  int _rate = 16000;
  bool capturing = false;
  bool playing = false;
  final List<Int16List> _toCapture = [];
  final List<int> played = [];

  void inject(Int16List samples) => _toCapture.add(samples);

  @override
  int get sampleRate => _rate;
  @override
  void init(int sampleRate) => _rate = sampleRate;
  @override
  void startCapture() => capturing = true;
  @override
  void stopCapture() => capturing = false;
  @override
  void startPlayback() => playing = true;
  @override
  void stopPlayback() => playing = false;

  @override
  Int16List readCaptured() {
    if (!capturing || _toCapture.isEmpty) return Int16List(0);
    final all = Int16List.fromList(_toCapture.expand((e) => e).toList());
    _toCapture.clear();
    return all;
  }

  @override
  void play(Int16List samples) => played.addAll(samples);
  @override
  int get queued => 0;
  @override
  void flushPlayback() {}
}
