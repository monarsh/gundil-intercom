import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the Windows runner's system tray (windows/runner/flutter_window.cpp).
/// Every call is a no-op on other platforms.
class WindowBridge {
  static const MethodChannel _channel = MethodChannel('gundil/window');

  static bool get supported => Platform.isWindows;

  /// When on, minimize and the close button hide the window to the tray
  /// (the intercom keeps receiving); right-click the tray icon > Exit quits.
  static Future<void> setTrayEnabled(bool enabled) =>
      _invoke('setTrayEnabled', enabled);

  /// Text shown when hovering the tray icon (max ~127 characters).
  static Future<void> setTooltip(String text) => _invoke('setTooltip', text);

  /// Brings the window back from the tray.
  static Future<void> show() => _invoke('show');

  static Future<void> _invoke(String method, [Object? args]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Running in a test harness.
    }
  }
}
