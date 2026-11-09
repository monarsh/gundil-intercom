/// FFI bindings to the native `intercom_audio` library (miniaudio based).
///
/// All functions are non-blocking: audio devices run on their own native
/// threads and exchange samples with Dart through lock-free ring buffers.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const String _libName = 'intercom_audio';

DynamicLibrary _open() {
  if (Platform.isAndroid) return DynamicLibrary.open('lib$_libName.so');
  if (Platform.isLinux) {
    // Flutter bundles put the library on the loader path. The headless node
    // (bin/gundil_node.dart) ships it next to the executable or in ./lib.
    final candidates = <String>['lib$_libName.so'];
    final override = Platform.environment['INTERCOM_AUDIO_LIB'];
    if (override != null && override.isNotEmpty) candidates.insert(0, override);
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates
      ..add('$exeDir/lib$_libName.so')
      ..add('$exeDir/lib/lib$_libName.so');
    Object? lastError;
    for (final c in candidates) {
      try {
        return DynamicLibrary.open(c);
      } catch (e) {
        lastError = e;
      }
    }
    throw ArgumentError('Could not load lib$_libName.so: $lastError');
  }
  if (Platform.isWindows) return DynamicLibrary.open('$_libName.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('lib$_libName.dylib');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

class _Native {
  _Native(DynamicLibrary lib)
    : init = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'ia_init',
      ),
      shutdown = lib.lookupFunction<Void Function(), void Function()>(
        'ia_shutdown',
      ),
      startCapture = lib.lookupFunction<Int32 Function(), int Function()>(
        'ia_start_capture',
      ),
      stopCapture = lib.lookupFunction<Void Function(), void Function()>(
        'ia_stop_capture',
      ),
      startPlayback = lib.lookupFunction<Int32 Function(), int Function()>(
        'ia_start_playback',
      ),
      stopPlayback = lib.lookupFunction<Void Function(), void Function()>(
        'ia_stop_playback',
      ),
      readCapture = lib
          .lookupFunction<
            Int32 Function(Pointer<Int16>, Int32),
            int Function(Pointer<Int16>, int)
          >('ia_read_capture'),
      writePlayback = lib
          .lookupFunction<
            Int32 Function(Pointer<Int16>, Int32),
            int Function(Pointer<Int16>, int)
          >('ia_write_playback'),
      playbackQueued = lib.lookupFunction<Int32 Function(), int Function()>(
        'ia_playback_queued',
      ),
      clearPlayback = lib.lookupFunction<Void Function(), void Function()>(
        'ia_clear_playback',
      ),
      lastError = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'ia_last_error',
          );

  final int Function(int) init;
  final void Function() shutdown;
  final int Function() startCapture;
  final void Function() stopCapture;
  final int Function() startPlayback;
  final void Function() stopPlayback;
  final int Function(Pointer<Int16>, int) readCapture;
  final int Function(Pointer<Int16>, int) writePlayback;
  final int Function() playbackQueued;
  final void Function() clearPlayback;
  final Pointer<Utf8> Function() lastError;
}

/// Thrown when the native audio layer reports a failure.
class AudioException implements Exception {
  AudioException(this.message);
  final String message;
  @override
  String toString() => 'AudioException: $message';
}

/// Singleton wrapper around the native audio engine.
///
/// Format is always signed 16-bit little-endian mono PCM at [sampleRate].
class IntercomAudio {
  IntercomAudio._(this._n);

  static IntercomAudio? _instance;

  /// Loads the native library. Throws if it is not available.
  static IntercomAudio get instance =>
      _instance ??= IntercomAudio._(_Native(_open()));

  final _Native _n;
  static const int _bufFrames = 16000;
  final Pointer<Int16> _buf = calloc<Int16>(_bufFrames);
  int sampleRate = 16000;
  bool _initialised = false;

  String get lastError => _n.lastError().toDartString();

  void init(int sampleRate) {
    if (_initialised) return;
    this.sampleRate = sampleRate;
    _check(_n.init(sampleRate));
    _initialised = true;
  }

  void startCapture() => _check(_n.startCapture());
  void stopCapture() => _n.stopCapture();
  void startPlayback() => _check(_n.startPlayback());
  void stopPlayback() => _n.stopPlayback();

  /// Returns all captured samples currently available (possibly empty).
  Int16List readCapture([int maxFrames = _bufFrames]) {
    final n = _n.readCapture(_buf, maxFrames.clamp(0, _bufFrames));
    return Int16List.fromList(_buf.asTypedList(n));
  }

  /// Queues samples for playback. Returns how many were accepted.
  int writePlayback(Int16List samples) {
    var written = 0;
    while (written < samples.length) {
      final chunk = (samples.length - written).clamp(0, _bufFrames);
      _buf.asTypedList(chunk).setRange(0, chunk, samples, written);
      final n = _n.writePlayback(_buf, chunk);
      written += n;
      if (n < chunk) break;
    }
    return written;
  }

  int get playbackQueued => _n.playbackQueued();
  void clearPlayback() => _n.clearPlayback();

  void shutdown() {
    _n.shutdown();
    _initialised = false;
  }

  void _check(int rc) {
    if (rc != 0) throw AudioException(lastError);
  }
}
