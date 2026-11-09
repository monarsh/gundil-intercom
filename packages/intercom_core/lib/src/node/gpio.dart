import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal GPIO access for the headless node, without native libraries.
///
/// Two backends:
/// * **gpiod** (preferred): uses the `gpiomon` / `gpioset` tools from the
///   `gpiod` package, which can enable the internal pull-up resistor.
///   Works with libgpiod v1 and v2.
/// * **sysfs**: `/sys/class/gpio`, available on most Armbian / Orange Pi
///   images. Cannot enable pull-ups, so wire a 10 kΩ resistor from the pin
///   to 3.3 V (or use an active-high button with a pull-down).
///
/// On the Orange Pi PC (Allwinner H3) the GPIO number is
/// `(port letter index) * 32 + pin`, e.g. PA6 = 6, PG7 = 6*32+7 = 199,
/// and gpiod line numbers on `gpiochip0` are the same.
enum GpioBackend { gpiod, sysfs }

Future<GpioBackend> detectGpioBackend(String preference) async {
  switch (preference) {
    case 'gpiod':
      return GpioBackend.gpiod;
    case 'sysfs':
      return GpioBackend.sysfs;
  }
  if (await _which('gpiomon')) return GpioBackend.gpiod;
  return GpioBackend.sysfs;
}

Future<bool> _which(String tool) async {
  try {
    final r = await Process.run('sh', ['-c', 'command -v $tool']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<int> _gpiodMajorVersion() async {
  try {
    final r = await Process.run('gpiomon', ['--version']);
    final m = RegExp(r'v?(\d+)\.\d+').firstMatch('${r.stdout}');
    if (m != null) return int.parse(m.group(1)!);
  } catch (_) {}
  return 1;
}

/// A push-button input. Emits true when pressed, false when released.
abstract class GpioButton {
  Stream<bool> get changes;
  Future<void> close();

  static Future<GpioButton> open({
    required int line,
    required bool activeLow,
    required GpioBackend backend,
    String chip = 'gpiochip0',
  }) async {
    return switch (backend) {
      GpioBackend.gpiod => _GpiodButton.start(line, activeLow, chip),
      GpioBackend.sysfs => _SysfsButton.start(line, activeLow),
    };
  }
}

/// An output pin (LED).
abstract class GpioOutput {
  Future<void> set(bool on);
  Future<void> close();

  static Future<GpioOutput> open({
    required int line,
    required GpioBackend backend,
    String chip = 'gpiochip0',
  }) async {
    return switch (backend) {
      GpioBackend.gpiod => _GpiodOutput(line, chip),
      GpioBackend.sysfs => await _SysfsOutput.start(line),
    };
  }
}

// ------------------------------------------------------------------- sysfs

/// sysfs GPIO root; `GUNDIL_GPIO_SYSFS` overrides it (used by tests).
String get _sysfs =>
    Platform.environment['GUNDIL_GPIO_SYSFS'] ?? '/sys/class/gpio';

Future<void> _sysfsExport(int line, String direction) async {
  final dir = Directory('$_sysfs/gpio$line');
  if (!dir.existsSync()) {
    try {
      File('$_sysfs/export').writeAsStringSync('$line');
    } on FileSystemException {
      // Already exported by someone else, or not permitted; checked below.
    }
    // udev may need a moment to fix permissions.
    for (var i = 0; i < 20 && !dir.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  if (!dir.existsSync()) {
    throw StateError(
      'GPIO $line is not available in $_sysfs (run as root, or install the '
      '"gpiod" package and use gpio-backend=gpiod)',
    );
  }
  File('${dir.path}/direction').writeAsStringSync(direction);
}

class _SysfsButton implements GpioButton {
  _SysfsButton(this._value, this._activeLow);

  final File _value;
  final bool _activeLow;
  final _controller = StreamController<bool>.broadcast();
  Timer? _timer;
  bool? _stable;
  bool? _last;

  static Future<GpioButton> start(int line, bool activeLow) async {
    await _sysfsExport(line, 'in');
    final b = _SysfsButton(File('$_sysfs/gpio$line/value'), activeLow);
    // Poll every 15 ms; a change must be seen twice in a row (debounce).
    b._timer = Timer.periodic(
      const Duration(milliseconds: 15),
      (_) => b._poll(),
    );
    return b;
  }

  void _poll() {
    bool pressed;
    try {
      final high = _value.readAsStringSync().trim() == '1';
      pressed = _activeLow ? !high : high;
    } catch (_) {
      return;
    }
    if (pressed == _last && pressed != _stable) {
      _stable = pressed;
      _controller.add(pressed);
    }
    _last = pressed;
  }

  @override
  Stream<bool> get changes => _controller.stream;

  @override
  Future<void> close() async {
    _timer?.cancel();
    await _controller.close();
  }
}

class _SysfsOutput implements GpioOutput {
  _SysfsOutput(this._value);
  final File _value;

  static Future<GpioOutput> start(int line) async {
    await _sysfsExport(line, 'out');
    return _SysfsOutput(File('$_sysfs/gpio$line/value'));
  }

  @override
  Future<void> set(bool on) async {
    try {
      _value.writeAsStringSync(on ? '1' : '0');
    } catch (_) {}
  }

  @override
  Future<void> close() => set(false);
}

// ------------------------------------------------------------------- gpiod

class _GpiodButton implements GpioButton {
  _GpiodButton(this._process, this._activeLow, this._v2) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _process.stderr.transform(utf8.decoder).listen((e) => stderr.write(e));
  }

  final Process _process;
  final bool _activeLow;
  final bool _v2;
  final _controller = StreamController<bool>.broadcast();
  bool? _pressed;

  static Future<GpioButton> start(int line, bool activeLow, String chip) async {
    final v2 = await _gpiodMajorVersion() >= 2;
    final bias = activeLow ? 'pull-up' : 'pull-down';
    final args = v2
        ? ['-c', chip, '-b', bias, '-F', '%e', '$line']
        : ['-B', bias, '-F', '%e', chip, '$line'];
    final p = await Process.start('gpiomon', args);
    return _GpiodButton(p, activeLow, v2);
  }

  void _onLine(String line) {
    final e = line.trim();
    // %e: v1 prints 1 (rising) / 0 (falling); v2 prints 1 / 2.
    final rising = e == '1';
    final falling = _v2 ? e == '2' : e == '0';
    if (!rising && !falling) return;
    final pressed = _activeLow ? falling : rising;
    // Contact bounce produces repeated edges; only report real changes.
    // (Never drop a release: a stuck transmit is worse than a double press.)
    if (pressed == _pressed) return;
    _pressed = pressed;
    _controller.add(pressed);
  }

  @override
  Stream<bool> get changes => _controller.stream;

  @override
  Future<void> close() async {
    _process.kill();
    await _controller.close();
  }
}

class _GpiodOutput implements GpioOutput {
  _GpiodOutput(this._line, this._chip);
  final int _line;
  final String _chip;
  Process? _holder;
  bool? _state;

  @override
  Future<void> set(bool on) async {
    if (_state == on) return;
    _state = on;
    // gpioset releases the line when it exits; keep it running while lit.
    _holder?.kill();
    _holder = null;
    try {
      final v2 = await _gpiodMajorVersion() >= 2;
      final value = on ? '1' : '0';
      _holder = await Process.start(
        'gpioset',
        v2
            ? ['-c', _chip, '$_line=$value']
            : ['--mode=signal', _chip, '$_line=$value'],
      );
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    await set(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _holder?.kill();
  }
}
