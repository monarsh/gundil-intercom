import 'dart:collection';
import 'dart:typed_data';

/// Per-peer jitter buffer: absorbs network timing variation so playback is
/// smooth, and caps latency by dropping the oldest audio when it grows.
class JitterBuffer {
  JitterBuffer({required this.prebuffer, required this.maxSamples});

  /// Samples to collect before playback starts (and after an underrun).
  final int prebuffer;

  /// Above this, the oldest audio is dropped to keep latency low.
  final int maxSamples;

  final Queue<Int16List> _chunks = Queue<Int16List>();
  int _offset = 0; // read position inside the first chunk
  int _count = 0;
  bool _primed = false;

  int get length => _count;
  bool get primed => _primed;

  void add(Int16List samples) {
    if (samples.isEmpty) return;
    _chunks.add(samples);
    _count += samples.length;
    if (_count > maxSamples) _drop(_count - (maxSamples + prebuffer) ~/ 2);
    if (!_primed && _count >= prebuffer) _primed = true;
  }

  /// Adds up to [n] samples into [mix] (starting at 0). Returns how many
  /// samples were available. Un-primes on underrun so the buffer refills.
  int mixInto(Int32List mix, int n) {
    if (!_primed) return 0;
    var written = 0;
    while (written < n && _chunks.isNotEmpty) {
      final c = _chunks.first;
      final take = (c.length - _offset).clamp(0, n - written);
      for (var i = 0; i < take; i++) {
        mix[written + i] += c[_offset + i];
      }
      written += take;
      _offset += take;
      _count -= take;
      if (_offset >= c.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
    }
    if (_count == 0) _primed = false;
    return written;
  }

  void _drop(int n) {
    while (n > 0 && _chunks.isNotEmpty) {
      final c = _chunks.first;
      final avail = c.length - _offset;
      if (avail <= n) {
        _chunks.removeFirst();
        _offset = 0;
        _count -= avail;
        n -= avail;
      } else {
        _offset += n;
        _count -= n;
        n = 0;
      }
    }
  }

  void clear() {
    _chunks.clear();
    _offset = 0;
    _count = 0;
    _primed = false;
  }
}

/// Mixes the audio of several peers into one stream for the speaker.
class AudioMixer {
  AudioMixer({required int sampleRate})
    : prebuffer = sampleRate * 60 ~/ 1000,
      maxBuffered = sampleRate * 300 ~/ 1000;

  /// 60 ms of audio is collected per peer before it is played.
  final int prebuffer;

  /// More than 300 ms queued for a peer is trimmed.
  final int maxBuffered;

  final Map<String, JitterBuffer> _buffers = {};

  void add(String peerId, Int16List samples) {
    _buffers
        .putIfAbsent(
          peerId,
          () => JitterBuffer(prebuffer: prebuffer, maxSamples: maxBuffered),
        )
        .add(samples);
  }

  void remove(String peerId) => _buffers.remove(peerId);
  void clear() => _buffers.clear();

  /// Returns [n] mixed samples, or null when nobody has audio ready.
  Int16List? take(int n) {
    if (n <= 0) return null;
    final acc = Int32List(n);
    var any = false;
    for (final b in _buffers.values) {
      if (b.mixInto(acc, n) > 0) any = true;
    }
    if (!any) return null;
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      final v = acc[i];
      out[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
    }
    return out;
  }
}
