import 'dart:io';

/// Settings of the headless intercom node.
///
/// Read from a `key = value` file (default `/etc/gundil-intercom/node.conf`)
/// and overridden by `--key=value` command-line options. `#` starts a comment.
class NodeConfig {
  NodeConfig(this.values);

  final Map<String, String> values;

  static const defaultPath = '/etc/gundil-intercom/node.conf';

  /// Every option with its description, for `--help`.
  static const Map<String, String> options = {
    'name': 'Name shown to other intercoms (default: hostname)',
    'target':
        '"everyone" or the name of the intercom the button connects to '
        '(default: everyone)',
    'auto-answer':
        'Open incoming connections at once (default true). false = ring '
        'and wait for the button / "a"',
    'echo-suppression':
        'Lower the mic while the other side talks (default true)',
    'peers': 'Comma-separated host[:port] list to add by IP (optional)',
    'button-gpio':
        'GPIO number of the connect / hang-up button (e.g. 6 = PA6, pin 7)',
    'button-gpio-active-low':
        'true if the button connects the pin to GND (default true)',
    'gpio-backend': 'auto | gpiod | sysfs (default auto)',
    'gpio-chip': 'gpiochip for the gpiod backend (default gpiochip0)',
    'led-gpio':
        'GPIO number of an LED: on while connected, blinking while calling '
        'or ringing (optional)',
    'button-input':
        'Input device for a USB button/keyboard, e.g. /dev/input/event0',
    'button-key': 'Key code for button-input (default 57 = Space; 28 = Enter)',
    'tones': 'Play connect / hang-up / ring tones (default true)',
    'state':
        'File for the device id and learned peers '
        '(default /var/lib/gundil-intercom/state.json)',
    'port': 'TCP port (default 47801)',
  };

  static NodeConfig load(List<String> args) {
    final cli = <String, String>{};
    String? configPath;
    for (final a in args) {
      if (!a.startsWith('--')) continue;
      final body = a.substring(2);
      final eq = body.indexOf('=');
      final key = eq < 0 ? body : body.substring(0, eq);
      final value = eq < 0 ? 'true' : body.substring(eq + 1);
      if (key == 'config') {
        configPath = value;
      } else {
        cli[key] = value;
      }
    }
    final values = <String, String>{};
    final path = configPath ?? defaultPath;
    final file = File(path);
    if (file.existsSync()) {
      values.addAll(parse(file.readAsStringSync()));
    } else if (configPath != null) {
      throw FileSystemException('Config file not found', path);
    }
    values.addAll(cli);
    return NodeConfig(values);
  }

  /// Parses `key = value` lines.
  static Map<String, String> parse(String text) {
    final out = <String, String>{};
    for (var line in text.split('\n')) {
      final hash = line.indexOf('#');
      if (hash >= 0) line = line.substring(0, hash);
      line = line.trim();
      if (line.isEmpty) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    return out;
  }

  bool get help => values.containsKey('help') || values.containsKey('h');

  String? str(String key) {
    final v = values[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  int? integer(String key) {
    final v = str(key);
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null) throw FormatException('$key must be a number, got "$v"');
    return n;
  }

  bool flag(String key, {required bool fallback}) {
    final v = str(key)?.toLowerCase();
    if (v == null) return fallback;
    return v == 'true' || v == 'yes' || v == '1' || v == 'on';
  }

  List<String> list(String key) => (str(key) ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}
