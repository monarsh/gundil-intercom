import 'dart:io';

import 'package:flutter/services.dart';

import 'package:intercom_core/intercom_core.dart';

/// Thin bridge to Android-only platform features implemented in
/// `MainActivity.kt`. Every call is a no-op on desktop platforms.
class PlatformBridge {
  static const MethodChannel _channel = MethodChannel('p2p_intercom/platform');

  static bool get _android => Platform.isAndroid;

  /// Requests RECORD_AUDIO at runtime. Returns true when granted.
  static Future<bool> requestMicrophone() async {
    if (!_android) return true;
    try {
      return await _channel.invokeMethod<bool>('requestMicrophone') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Puts Android audio into voice-communication mode (enables the phone's
  /// echo canceller) and picks the output (see [getAudioRoutes]).
  static Future<void> startCallAudio() => _invoke('startCallAudio');
  static Future<void> stopCallAudio() => _invoke('stopCallAudio');

  /// Audio outputs: `{"active", "routes": [{"id","type","name"}], "current"}`.
  static Future<Map<Object?, Object?>?> getAudioRoutes() =>
      _map('getAudioRoutes');

  /// Switches the output; returns the new state.
  static Future<Map<Object?, Object?>?> setAudioRoute(String id) =>
      _map('setAudioRoute', {'id': id});

  /// Called by Android whenever outputs or the current output change.
  static void onAudioRoutesChanged(
    void Function(Map<Object?, Object?> state) handler,
  ) {
    if (!_android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioRoutesChanged' && call.arguments is Map) {
        handler(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
  }

  static Future<Map<Object?, Object?>?> _map(
    String method, [
    Object? args,
  ]) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Updates the background notification (Android background mode):
  /// e.g. "Connected with Gate". Empty title = back to "ready".
  static Future<void> setStatus(String title, String text) =>
      _invoke('setStatus', {'title': title, 'text': text});

  /// Many Android devices drop broadcast/multicast packets unless a Wi-Fi
  /// multicast lock is held.
  static Future<void> acquireMulticastLock() => _invoke('acquireMulticastLock');
  static Future<void> releaseMulticastLock() => _invoke('releaseMulticastLock');

  // ------------------------------------------------- Android background mode

  /// Whether the background service (persistent notification) is enabled.
  static Future<bool> getBackground() => _get('getBackground');

  /// Starts/stops the background service and remembers the choice.
  static Future<bool> setBackground(bool enabled) =>
      _get('setBackground', {'enabled': enabled});

  /// Whether the background service starts after the phone boots.
  static Future<bool> getStartOnBoot() => _get('getStartOnBoot');
  static Future<bool> setStartOnBoot(bool enabled) =>
      _get('setStartOnBoot', {'enabled': enabled});

  /// Android 13+: permission to show the background notification.
  static Future<bool> requestNotifications() => _get('requestNotifications');

  static Future<bool> isIgnoringBatteryOptimizations() =>
      _get('isIgnoringBatteryOptimizations');

  /// Opens the system prompt to exempt the app from battery optimization,
  /// so Android doesn't cut its network while the screen is off.
  static Future<void> requestIgnoreBatteryOptimizations() =>
      _invoke('requestIgnoreBatteryOptimizations');

  static Future<bool> _get(String method, [Object? args]) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _invoke(String method, [Object? args]) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Running in a test harness.
    }
  }
}

/// Android implementations of the engine's platform hooks.
class FlutterPlatformHooks extends PlatformHooks {
  const FlutterPlatformHooks();

  @override
  Future<bool> requestMicrophone() => PlatformBridge.requestMicrophone();

  @override
  Future<void> acquireMulticastLock() => PlatformBridge.acquireMulticastLock();

  @override
  Future<void> releaseMulticastLock() => PlatformBridge.releaseMulticastLock();

  @override
  Future<void> startCallAudio() => PlatformBridge.startCallAudio();

  @override
  Future<void> stopCallAudio() => PlatformBridge.stopCallAudio();
}
