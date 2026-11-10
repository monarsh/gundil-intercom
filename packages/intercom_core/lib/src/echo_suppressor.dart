import 'dart:math' as math;
import 'dart:typed_data';

/// Simple echo suppression for devices without a hardware echo canceller
/// (PCs, Orange Pi, Raspberry Pi).
///
/// In a two-way intercom on loudspeakers, the remote voice comes out of our
/// speaker, goes into our microphone and is sent back: the far end hears
/// itself, and with two open speakers it can howl. This class turns our
/// outgoing microphone down while the far end is talking and we are not
/// clearly louder than the echo, which is how speakerphones without real
/// echo cancellation work. When we start talking over them, the
/// microphone opens again ("barge-in").
class EchoSuppressor {
  EchoSuppressor({
    required this.sampleRate,
    this.duckGain = 0.08,
    this.farThreshold = 0.004,
    this.bargeInRatio = 2.5,
    Duration hold = const Duration(milliseconds: 250),
  }) : _holdSamples = sampleRate * hold.inMilliseconds ~/ 1000;

  final int sampleRate;

  /// Microphone gain while the far end is talking (0.08 ≈ -22 dB).
  final double duckGain;

  /// Far-end level (linear RMS) above which we consider them talking.
  final double farThreshold;

  /// We "barge in" when the mic is this many times louder than the far end.
  final double bargeInRatio;

  final int _holdSamples;

  double _far = 0; // smoothed far-end envelope
  int _farHold = 0; // samples to keep treating the far end as active
  double _gain = 1;

  /// Current microphone gain (1 = open, [duckGain] = suppressed).
  double get gain => _gain;

  /// Feeds what is about to be played on the speaker.
  void onPlayback(Int16List samples) {
    if (samples.isEmpty) return;
    final level = rms(samples);
    // Fast attack, slow release.
    _far = level > _far ? level : _far * 0.85 + level * 0.15;
    if (level > farThreshold) _farHold = _holdSamples + samples.length;
  }

  /// Applies suppression to a captured microphone chunk (in place).
  void process(Int16List mic) {
    if (mic.isEmpty) return;
    final near = rms(mic);
    _farHold = math.max(0, _farHold - mic.length);
    final farActive = _farHold > 0 && _far > farThreshold;
    final bargeIn = near > _far * bargeInRatio;
    final target = (farActive && !bargeIn) ? duckGain : 1.0;
    // Duck quickly; reopen a little slower to avoid chopping.
    final start = _gain;
    final end = target < _gain ? target : _gain + (target - _gain) * 0.5;
    for (var i = 0; i < mic.length; i++) {
      final g = start + (end - start) * (i / mic.length);
      mic[i] = (mic[i] * g).round().clamp(-32768, 32767);
    }
    _gain = end;
  }

  void reset() {
    _far = 0;
    _farHold = 0;
    _gain = 1;
  }

  static double rms(Int16List s) {
    if (s.isEmpty) return 0;
    var sum = 0.0;
    for (final v in s) {
      sum += v * v;
    }
    return math.sqrt(sum / s.length) / 32768.0;
  }
}
