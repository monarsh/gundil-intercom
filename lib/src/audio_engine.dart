import 'dart:typed_data';

import 'package:intercom_audio/intercom_audio.dart';

/// Abstraction over the microphone/speaker so the intercom logic can be tested
/// without real audio hardware.
abstract class AudioEngine {
  int get sampleRate;
  void init(int sampleRate);
  void start();
  void stop();

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
  void start() {
    _a.startPlayback();
    try {
      _a.startCapture();
    } catch (_) {
      _a.stopPlayback();
      rethrow;
    }
  }

  @override
  void stop() {
    _a.stopCapture();
    _a.stopPlayback();
  }

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
  bool running = false;
  final List<Int16List> _toCapture = [];
  final List<int> played = [];

  void inject(Int16List samples) => _toCapture.add(samples);

  @override
  int get sampleRate => _rate;
  @override
  void init(int sampleRate) => _rate = sampleRate;
  @override
  void start() => running = true;
  @override
  void stop() => running = false;

  @override
  Int16List readCaptured() {
    if (_toCapture.isEmpty) return Int16List(0);
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
