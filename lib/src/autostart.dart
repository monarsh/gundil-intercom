import 'dart:io';

/// "Start automatically when I sign in" support.
///
/// * Windows: a value in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
///   (the same entry the installer's "start automatically" option creates).
/// * Linux: an XDG autostart entry in `~/.config/autostart`.
///
/// The app is launched with `--minimized`, so it starts quietly in the
/// taskbar and still plays incoming talk.
class Autostart {
  Autostart._();

  static const String _name = 'Gundil Intercom';
  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String minimizedFlag = '--minimized';

  static bool get supported => Platform.isWindows || Platform.isLinux;

  static Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', _runKey, '/v', _name]);
        return r.exitCode == 0;
      }
      if (Platform.isLinux) return _desktopFile()?.existsSync() ?? false;
    } catch (_) {}
    return false;
  }

  /// Turns autostart on or off. Returns the resulting state.
  static Future<bool> setEnabled(bool enabled) async {
    // Inside an AppImage the executable lives in a temporary mount that
    // changes every launch; $APPIMAGE is the real file to start.
    final exe = Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;
    try {
      if (Platform.isWindows) {
        final args = enabled
            ? [
                'add',
                _runKey,
                '/v',
                _name,
                '/t',
                'REG_SZ',
                '/d',
                '"$exe" $minimizedFlag',
                '/f',
              ]
            : ['delete', _runKey, '/v', _name, '/f'];
        await Process.run('reg', args);
      } else if (Platform.isLinux) {
        final f = _desktopFile();
        if (f != null) {
          if (enabled) {
            await f.parent.create(recursive: true);
            await f.writeAsString(linuxDesktopEntry(exe));
          } else if (f.existsSync()) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
    return isEnabled();
  }

  /// Contents of the XDG autostart file for [exe].
  static String linuxDesktopEntry(String exe) {
    final quoted = exe.contains(' ') ? '"$exe"' : exe;
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=$_name\n'
        'Comment=Push-to-talk LAN intercom\n'
        'Exec=$quoted $minimizedFlag\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  static File? _desktopFile() {
    final config =
        Platform.environment['XDG_CONFIG_HOME'] ??
        (Platform.environment['HOME'] == null
            ? null
            : '${Platform.environment['HOME']}/.config');
    if (config == null) return null;
    return File('$config/autostart/gundil-intercom.desktop');
  }
}
