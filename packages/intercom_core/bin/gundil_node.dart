// Gundil Intercom headless node.
//
// Runs the intercom without a screen — e.g. on an Orange Pi PC / Raspberry Pi
// with a microphone, a speaker on the audio jack and a button on a GPIO pin.
// It finds the other intercoms on the LAN and holds two-way conversations:
// incoming connections are answered automatically (like a door station), and
// the button connects to the configured target or hangs up.
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
    rogerBeep: cfg.flag(
      'tones',
      fallback: cfg.flag('roger-beep', fallback: true),
    ),
    autoAnswer: cfg.flag('auto-answer', fallback: true),
    echoSuppression: cfg.flag('echo-suppression', fallback: true),
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
  final pttGpio = cfg.integer('button-gpio') ?? cfg.integer('ptt-gpio');
  final ledGpio = cfg.integer('led-gpio');
  if (pttGpio != null || ledGpio != null) {
    final backend = await detectGpioBackend(cfg.str('gpio-backend') ?? 'auto');
    final chip = cfg.str('gpio-chip') ?? 'gpiochip0';
    if (pttGpio != null) {
      try {
        final button = await GpioButton.open(
          line: pttGpio,
          activeLow: cfg.flag(
            'button-gpio-active-low',
            fallback: cfg.flag('ptt-gpio-active-low', fallback: true),
          ),
          backend: backend,
          chip: chip,
        );
        button.changes.listen(node.button);
        cleanups.add(button.close);
        log('Connect button on GPIO $pttGpio (${backend.name})');
      } catch (e) {
        log('ERROR: button GPIO $pttGpio: $e');
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

  final pttInput = cfg.str('button-input') ?? cfg.str('ptt-input');
  if (pttInput != null) {
    final code = cfg.integer('button-key') ?? cfg.integer('ptt-key') ?? 57;
    try {
      final key = InputKey.open(pttInput, code);
      key.changes.listen(
        node.button,
        onError: (Object e) => log('ERROR: $pttInput: $e'),
      );
      cleanups.add(key.close);
      log('Connect key $code on $pttInput');
    } catch (e) {
      log('ERROR: button-input $pttInput: $e');
    }
  }

  if (stdin.hasTerminal) {
    log(
      'Keys: [Enter] connect / accept / hang up · a = accept · d = decline · '
      'm = mute · l = list peers · t <name|everyone> = who to connect to · '
      'q = quit',
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
    core.hangUp();
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

  String _lastStatus = '';
  final Map<String, bool> _online = {};
  Timer? _blink;
  bool _ledState = false;
  String _ledMode = 'off';

  void watch() {
    core.events.listen((e) => log(e.error ? 'ERROR: ${e.message}' : e.message));
    core.onChange(_onChange);
  }

  void _onChange() {
    final conv = core.conversation;
    final String status;
    if (conv == null) {
      status = 'idle';
    } else if (core.ringing && !core.autoAnswer) {
      status =
          '🔔 ${conv.ringing.map(core.displayName).join(', ')} wants to '
          'talk (press the button or "a" to accept)';
    } else if (conv.isConnected) {
      status =
          '📞 connected with ${conv.connected.map(core.displayName).join(', ')}';
    } else if (conv.calling.isNotEmpty) {
      status = '… calling ${conv.calling.map(core.displayName).join(', ')}';
    } else {
      status = _lastStatus; // answering: about to connect
    }
    if (status != _lastStatus) {
      if (status == 'idle') {
        if (_lastStatus.isNotEmpty) log('   line closed');
      } else {
        log(status);
      }
      _lastStatus = status;
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
    // LED: on while connected, blinking while calling / ringing.
    _setLed(
      conv == null
          ? 'off'
          : conv.isConnected
          ? 'on'
          : 'blink',
    );
  }

  void _setLed(String mode) {
    if (mode == _ledMode || led == null) return;
    _ledMode = mode;
    _blink?.cancel();
    _blink = null;
    switch (mode) {
      case 'on':
        led!.set(true);
      case 'off':
        led!.set(false);
      case 'blink':
        _blink = Timer.periodic(const Duration(milliseconds: 400), (_) {
          _ledState = !_ledState;
          led!.set(_ledState);
        });
    }
  }

  /// The button (GPIO, USB key) was pressed (true) or released (false).
  /// Press: connect / accept / hang up. Release: nothing.
  void button(bool pressed) {
    if (pressed) toggle();
  }

  void toggle() {
    final conv = core.conversation;
    if (conv != null && core.ringing) {
      core.accept();
    } else if (conv != null) {
      core.hangUp();
    } else {
      final t = _resolveTarget();
      if (t == null) return;
      core.selectTarget(t);
      log('… connecting to ${core.targetName(t)}');
      core.connect(t);
    }
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
      toggle();
    } else if (cmd == 'q' || cmd == 'quit') {
      onQuit?.call();
    } else if (cmd == 'a') {
      core.accept();
    } else if (cmd == 'd') {
      core.decline();
    } else if (cmd == 'h') {
      core.hangUp();
    } else if (cmd == 'm') {
      core.toggleMute();
      log(core.muted ? '🔇 microphone muted' : '🎙 microphone on');
    } else if (cmd == 'l' || cmd == 'list') {
      final entries = core.entries;
      if (entries.isEmpty) log('No peers yet.');
      for (final e in entries) {
        log(
          '  ${e.online ? '●' : '○'} ${e.name}  ${e.host}:${e.port}  '
          '${e.platform}${e.isSaved ? '  (saved)' : ''}'
          '${e.live?.outdated ?? false ? '  (needs update)' : ''}',
        );
      }
      log('Button connects to: $targetName');
    } else if (cmd.startsWith('t ')) {
      targetName = cmd.substring(2).trim();
      log('The button now connects to: $targetName');
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
Gundil Intercom headless node — two-way LAN intercom without a screen.

Usage: gundil-intercom-node [--config=FILE] [--option=value ...]

Options (also usable as "option = value" lines in the config file,
default ${NodeConfig.defaultPath}):''');
  for (final e in NodeConfig.options.entries) {
    stdout.writeln('  --${e.key.padRight(22)} ${e.value}');
  }
  stdout.writeln('''
  --config=FILE            Use another config file
  --help                   Show this help

When run in a terminal: Enter = connect / accept / hang up, "a" accept,
"d" decline, "m" mute, "l" list peers, "t <name>" choose who the button
connects to, "q" quit.''');
}
