/// Flutter FFI plugin that builds and bundles the native `intercom_audio`
/// library (miniaudio) for Linux, Windows and Android.
///
/// The Dart bindings live in the pure-Dart `intercom_core` package so the
/// headless node can use them without Flutter.
library;

export 'package:intercom_core/intercom_core.dart'
    show IntercomAudio, AudioException;
