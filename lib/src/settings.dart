import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent user settings.
///
/// Set the environment variable `P2P_INTERCOM_PROFILE` to run several
/// independent instances on the same computer (each gets its own identity).
class Settings {
  Settings._(this._prefs) : _p = _profilePrefix();

  final SharedPreferences _prefs;
  final String _p;

  static String _profilePrefix() {
    final profile = Platform.environment['P2P_INTERCOM_PROFILE'];
    return (profile == null || profile.isEmpty) ? '' : '$profile.';
  }

  static Future<Settings> load() async =>
      Settings._(await SharedPreferences.getInstance());

  /// Stable random identifier of this installation.
  String get deviceId {
    var id = _prefs.getString('${_p}deviceId');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(
        16,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _prefs.setString('${_p}deviceId', id);
    }
    return id;
  }

  String get name =>
      _prefs.getString('${_p}name') ??
      (_p.isEmpty ? _defaultName() : _p.substring(0, _p.length - 1));
  set name(String v) => _prefs.setString('${_p}name', v);

  /// Manually added peers as "host:port" strings.
  List<String> get manualPeers =>
      _prefs.getStringList('${_p}manualPeers') ?? [];
  set manualPeers(List<String> v) =>
      _prefs.setStringList('${_p}manualPeers', v);

  static String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {}
    final os = Platform.operatingSystem;
    return '${os[0].toUpperCase()}${os.substring(1)} intercom';
  }
}
