// Gundil Intercom headless node.
//
// Runs the intercom without a screen — e.g. on an Orange Pi PC / Raspberry Pi
// with a microphone, a speaker on the audio jack and a push-to-talk button on
// a GPIO pin. It finds the other intercoms on the LAN, plays incoming talk,
// and transmits while the button is held.
//
// Build (also cross-compiles, see tool/build_node.sh):
//   dart compile exe bin/gundil_node.dart -o gundil-intercom-node
//
// Run `gundil-intercom-node --help` for options.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/node.dart';

void log(String msg) {
  final t = DateTime.now().toIso8601String().substring(11, 19);
  stdout.writeln('$t $msg');
}

Future<void> main(List<String> args) async {
  final NodeConfig cfg;
  try {
    cfg = NodeConfig.load(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    exit(2);
  }
  if (cfg.help) {
    _printHelp();
    return;
  }
  IntercomCore.log = (m) => log('debug: $m');

  final state = _NodeState.load(cfg.str('state'));
  final name = cfg.str('name') ?? _hostname();

  // Peers listed in the config are always kept in the saved list.
  final saved = [...state.saved];
  for (final entry in cfg.list('peers')) {
    final (host, port) = _parseEndpoint(entry);
    if (!saved.any((s) => s.host == host && s.port == port)) {
      saved.add(SavedPeer(key: 'cfg-$host-$port', host: host, port: port));
    }
  }

  final core = IntercomCore(
    selfId: state.deviceId,
    name: name,
    audio: NativeAudioEngine(),
    preferredPort: cfg.integer('port') ?? defaultTcpPort,
    rogerBeep: cfg.flag('roger-beep', fallback: true),
    savedPeers: saved,
    onSavedPeersChanged: (list) => state.save(saved: list),
  );

  // Fail early (with a clear message) if the audio library or devices are
  // missing, instead of on the first button press.
  try {
    NativeAudioEngine().init(defaultSampleRate);
  } catch (e) {
    stderr.writeln('Audio is not available: $e');
    stderr.writeln(
      'Is libintercom_audio.so next to the executable (or in '
      './lib)? Is ALSA/PulseAudio working (try: aplay -l, arecord -l)?',
    );
    exit(1);
  }

  await core.start();
  log(
    'Gundil Intercom node "$name" listening on TCP ${core.listenPort}, '
    'discovery ${core.discoveryRunning ? 'on' : 'OFF'}',
  );

  final target = cfg.str('target') ?? 'everyone';
  final node = _Node(core, target);
  node.watch();

  final cleanups = <Future<void> Function()>[];

  // ------------------------------------------------------------- inputs
  final pttGpio = cfg.integer('ptt-gpio');
  final ledGpio = cfg.integer('led-gpio');
  if (pttGpio != null || ledGpio != null) {
    final backend = await detectGpioBackend(cfg.str('gpio-backend') ?? 'auto');
    final chip = cfg.str('gpio-chip') ?? 'gpiochip0';
    if (pttGpio != null) {
      try {
        final button = await GpioButton.open(
          line: pttGpio,
          activeLow: cfg.flag('ptt-gpio-active-low', fallback: true),
          backend: backend,
          chip: chip,
        );
        button.changes.listen(node.ptt);
        cleanups.add(button.close);
        log('Push-to-talk button on GPIO $pttGpio (${backend.name})');
      } catch (e) {
        log('ERROR: push-to-talk GPIO $pttGpio: $e');
      }
    }
    if (ledGpio != null) {
      try {
        final led = await GpioOutput.open(
          line: ledGpio,
          backend: backend,
          chip: chip,
        );
        node.led = led;
        cleanups.add(led.close);
        log('Activity LED on GPIO $ledGpio (${backend.name})');
      } catch (e) {
        log('ERROR: LED GPIO $ledGpio: $e');
      }
    }
  }

  final pttInput = cfg.str('ptt-input');
  if (pttInput != null) {
    final code = cfg.integer('ptt-key') ?? 57;
    try {
      final key = InputKey.open(pttInput, code);
      key.changes.listen(
        node.ptt,
        onError: (Object e) => log('ERROR: $pttInput: $e'),
      );
      cleanups.add(key.close);
      log('Push-to-talk key $code on $pttInput');
    } catch (e) {
      log('ERROR: ptt-input $pttInput: $e');
    }
  }

  if (stdin.hasTerminal) {
    log(
      'Keys: [Enter] start/stop talking · l = list peers · '
      't <name|everyone> = talk to · q = quit',
    );
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(node.command);
  }

  // ------------------------------------------------------------- shutdown
  var stopping = false;
  Future<void> stop(ProcessSignal s) async {
    if (stopping) return;
    stopping = true;
    log('Stopping (${s.name})');
    core.stopTalking();
    for (final c in cleanups) {
      try {
        await c();
      } catch (_) {}
    }
    await core.shutdown();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);
  node.onQuit = () => stop(ProcessSignal.sigterm);
}

/// Glue between inputs (button, keyboard) and the intercom core.
class _Node {
  _Node(this.core, this.targetName);

  final IntercomCore core;
  String targetName;
  GpioOutput? led;
  void Function()? onQuit;

  String? _lastTalker;
  final Map<String, bool> _online = {};
  bool? _ledOn;

  void watch() {
    core.events.listen((e) => log(e.error ? 'ERROR: ${e.message}' : e.message));
    core.onChange(_onChange);
  }

  void _onChange() {
    final incoming = core.incoming;
    final talker = incoming == null ? null : core.displayName(incoming.peerId);
    if (talker != _lastTalker) {
      if (talker != null) {
        log('🔊 $talker is talking${incoming!.group ? ' to everyone' : ''}');
      } else if (_lastTalker != null) {
        log('   $_lastTalker finished');
      }
      _lastTalker = talker;
    }
    for (final e in core.entries) {
      final was = _online[e.key];
      if (was != e.online) {
        _online[e.key] = e.online;
        if (was != null || e.online) {
          log(
            '${e.online ? '+' : '-'} ${e.name} (${e.host}) '
            '${e.online ? 'online' : 'offline'}',
          );
        }
      }
    }
    final ledOn = core.transmitting || incoming != null;
    if (ledOn != _ledOn) {
      _ledOn = ledOn;
      led?.set(ledOn);
    }
  }

  /// Push-to-talk pressed (true) / released (false).
  void ptt(bool pressed) {
    if (!pressed) {
      if (core.pttHeld) {
        core.stopTalking();
        log('🎙 stopped talking');
      }
      return;
    }
    final t = _resolveTarget();
    if (t == null) return;
    core.selectTarget(t);
    log('🎙 talking to ${core.targetName(t)}');
    core.startTalking();
  }

  TalkTarget? _resolveTarget() {
    final want = targetName.trim().toLowerCase();
    if (want.isEmpty || want == 'everyone' || want == 'all') {
      return const EveryoneTarget();
    }
    for (final e in core.entries) {
      if (e.name.toLowerCase() == want && e.peerId != null) {
        if (!e.online) {
          log('ERROR: ${e.name} is offline');
          return null;
        }
        return PeerTarget(e.peerId!);
      }
    }
    log(
      'ERROR: no peer named "$targetName" '
      '(known: ${core.entries.map((e) => e.name).join(', ')})',
    );
    return null;
  }

  void command(String line) {
    final cmd = line.trim();
    if (cmd.isEmpty) {
      ptt(!core.pttHeld);
    } else if (cmd == 'q' || cmd == 'quit') {
      onQuit?.call();
    } else if (cmd == 'l' || cmd == 'list') {
      final entries = core.entries;
      if (entries.isEmpty) log('No peers yet.');
      for (final e in entries) {
        log(
          '  ${e.online ? '●' : '○'} ${e.name}  ${e.host}:${e.port}  '
          '${e.platform}${e.isSaved ? '  (saved)' : ''}',
        );
      }
      log('Talking to: $targetName');
    } else if (cmd.startsWith('t ')) {
      targetName = cmd.substring(2).trim();
      log('Push-to-talk now talks to: $targetName');
    } else {
      log('Unknown command "$cmd"');
    }
  }
}

/// Persistent identity and learned peers.
class _NodeState {
  _NodeState(this.file, this.deviceId, this.saved);

  final File file;
  final String deviceId;
  final List<SavedPeer> saved;

  static _NodeState load(String? path) {
    final file = File(path ?? _defaultStatePath());
    String? id;
    var saved = <SavedPeer>[];
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map) {
        id = json['deviceId'] as String?;
        final list = json['savedPeers'];
        if (list is List) {
          saved = list.map(SavedPeer.fromJson).whereType<SavedPeer>().toList();
        }
      }
    } catch (_) {}
    if (id == null) {
      final r = Random.secure();
      id = List.generate(
        16,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    final s = _NodeState(file, id, saved);
    s.save(saved: saved);
    return s;
  }

  void save({required List<SavedPeer> saved}) {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'deviceId': deviceId,
          'savedPeers': [for (final s in saved) s.toJson()],
        }),
      );
    } catch (e) {
      log('WARNING: cannot save state to ${file.path}: $e');
    }
  }

  static String _defaultStatePath() {
    const system = '/var/lib/gundil-intercom/state.json';
    try {
      Directory('/var/lib/gundil-intercom').createSync(recursive: true);
      final probe = File('/var/lib/gundil-intercom/.probe')
        ..writeAsStringSync('');
      probe.deleteSync();
      return system;
    } catch (_) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/.config/gundil-intercom/state.json';
    }
  }
}

String _hostname() {
  try {
    final h = Platform.localHostname;
    if (h.isNotEmpty && h != 'localhost') return h;
  } catch (_) {}
  return 'Intercom node';
}

(String, int) _parseEndpoint(String s) {
  final i = s.lastIndexOf(':');
  if (i > 0) {
    final p = int.tryParse(s.substring(i + 1));
    if (p != null) return (s.substring(0, i), p);
  }
  return (s, defaultTcpPort);
}

void _printHelp() {
  stdout.writeln('''
Gundil Intercom headless node — push-to-talk LAN intercom without a screen.

Usage: gundil-intercom-node [--config=FILE] [--option=value ...]

Options (also usable as "option = value" lines in the config file,
default ${NodeConfig.defaultPath}):''');
  for (final e in NodeConfig.options.entries) {
    stdout.writeln('  --${e.key.padRight(22)} ${e.value}');
  }
  stdout.writeln('''
  --config=FILE            Use another config file
  --help                   Show this help

When run in a terminal: press Enter to start/stop talking, "l" to list peers,
"t <name>" to choose who to talk to, "q" to quit.''');
}
