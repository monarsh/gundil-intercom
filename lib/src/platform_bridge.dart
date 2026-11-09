import 'dart:io';

import 'package:flutter/services.dart';

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

  /// Many Android devices drop broadcast/multicast packets unless a Wi-Fi
  /// multicast lock is held.
  static Future<void> acquireMulticastLock() => _invoke('acquireMulticastLock');
  static Future<void> releaseMulticastLock() => _invoke('releaseMulticastLock');

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
