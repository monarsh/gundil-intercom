import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'protocol.dart';

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

  static Future<Settings> load() async {
    await _migrateWindowsDataFolder();
    return Settings._(await SharedPreferences.getInstance());
  }

  /// On Windows, settings live in %APPDATA%\<company>\<product name>. The
  /// product was renamed from "P2P Intercom" to "Gundil Intercom", so copy
  /// the old settings file (device id, name, saved peers) over once.
  static Future<void> _migrateWindowsDataFolder() async {
    if (!Platform.isWindows) return;
    try {
      final dir = await getApplicationSupportDirectory();
      const fileName = 'shared_preferences.json';
      final current = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (current.existsSync()) return;
      final old = File(
        '${dir.parent.path}${Platform.pathSeparator}P2P Intercom'
        '${Platform.pathSeparator}$fileName',
      );
      if (!old.existsSync()) return;
      await current.parent.create(recursive: true);
      await old.copy(current.path);
    } catch (_) {
      // Best effort: worst case the user re-adds their peers.
    }
  }

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

  /// Peers the user saved; they stay in the list across restarts.
  List<SavedPeer> get savedPeers {
    final raw = _prefs.getString('${_p}savedPeers');
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          return list.map(SavedPeer.fromJson).whereType<SavedPeer>().toList();
        }
      } catch (_) {}
      return [];
    }
    // Migrate the old "host:port" list from earlier versions.
    final legacy = _prefs.getStringList('${_p}manualPeers') ?? const [];
    var i = 0;
    return [
      for (final e in legacy)
        if (_parseLegacy(e) case (final host, final port))
          SavedPeer(key: 'legacy${i++}', host: host, port: port),
    ];
  }

  set savedPeers(List<SavedPeer> v) {
    _prefs.setString(
      '${_p}savedPeers',
      jsonEncode([for (final s in v) s.toJson()]),
    );
    _prefs.remove('${_p}manualPeers');
  }

  static (String, int)? _parseLegacy(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0) return s.isEmpty ? null : (s, defaultTcpPort);
    final port = int.tryParse(s.substring(i + 1));
    return port == null ? (s, defaultTcpPort) : (s.substring(0, i), port);
  }

  static String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {}
    final os = Platform.operatingSystem;
    return '${os[0].toUpperCase()}${os.substring(1)} intercom';
  }
}
