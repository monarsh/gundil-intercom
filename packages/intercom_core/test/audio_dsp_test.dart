import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Int16List constant(int n, int v) => Int16List.fromList(List.filled(n, v));

Int16List sine(int n, double amp, {double freq = 440, int rate = 16000}) =>
    Int16List.fromList([
      for (var i = 0; i < n; i++)
        (amp * 32767 * math.sin(2 * math.pi * freq * i / rate)).round(),
    ]);

void main() {
  group('JitterBuffer', () {
    test('waits for the prebuffer, then plays in order', () {
      final b = JitterBuffer(prebuffer: 100, maxSamples: 1000);
      b.add(constant(50, 1));
      final mix = Int32List(50);
      expect(b.mixInto(mix, 50), 0); // not primed yet
      b.add(constant(60, 2));
      expect(b.primed, isTrue);
      final out = Int32List(80);
      expect(b.mixInto(out, 80), 80);
      expect(out.sublist(0, 50).every((v) => v == 1), isTrue);
      expect(out.sublist(50).every((v) => v == 2), isTrue);
    });

    test('underrun re-primes; overflow drops the oldest audio', () {
      final b = JitterBuffer(prebuffer: 10, maxSamples: 100);
      b.add(constant(20, 1));
      b.mixInto(Int32List(30), 30);
      expect(b.primed, isFalse);
      for (var i = 0; i < 20; i++) {
        b.add(constant(10, i));
      }
      expect(b.length, lessThanOrEqualTo(100));
      final out = Int32List(1);
      b.mixInto(out, 1);
      expect(out[0], greaterThan(0)); // oldest chunks were dropped
    });
  });

  group('AudioMixer', () {
    test('sums peers and clips to 16 bit', () {
      final m = AudioMixer(sampleRate: 16000);
      m.add('a', constant(2000, 20000));
      m.add('b', constant(2000, 20000));
      m.add('c', constant(2000, -5));
      final out = m.take(320)!;
      expect(out.every((v) => v == 32767), isTrue);
    });

    test('returns null when nobody has audio', () {
      final m = AudioMixer(sampleRate: 16000);
      expect(m.take(320), isNull);
      m.add('a', constant(100, 1)); // below the 60 ms prebuffer
      expect(m.take(320), isNull);
    });
  });

  group('EchoSuppressor', () {
    test('ducks the mic while the far end talks', () {
      final e = EchoSuppressor(sampleRate: 16000);
      for (var i = 0; i < 10; i++) {
        e.onPlayback(sine(320, 0.3));
        e.process(sine(320, 0.05)); // echo: quieter than the far end
      }
      expect(e.gain, closeTo(e.duckGain, 0.01));
      final mic = sine(320, 0.05);
      e.process(mic);
      expect(EchoSuppressor.rms(mic), lessThan(0.01));
    });

    test('opens again when we talk over them (barge-in)', () {
      final e = EchoSuppressor(sampleRate: 16000);
      for (var i = 0; i < 10; i++) {
        e.onPlayback(sine(320, 0.05));
        e.process(sine(320, 0.6)); // we're much louder than the echo
      }
      expect(e.gain, greaterThan(0.9));
    });

    test('stays open when the far end is silent', () {
      final e = EchoSuppressor(sampleRate: 16000);
      for (var i = 0; i < 30; i++) {
        e.onPlayback(Int16List(320));
        e.process(sine(320, 0.05));
      }
      expect(e.gain, greaterThan(0.95));
    });
  });
}
