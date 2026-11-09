@TestOn('linux')
library;

import 'dart:io';

import 'package:intercom_core/node.dart';
import 'package:test/test.dart';

/// Runs the sysfs backend against a fake /sys/class/gpio tree. The test
/// re-launches itself with GUNDIL_GPIO_SYSFS set, because the variable is read
/// from the environment.
void main() {
  final root = Platform.environment['GUNDIL_GPIO_SYSFS'];

  if (root == null) {
    test('sysfs backend (in a child process with a fake sysfs)', () async {
      final tmp = await Directory.systemTemp.createTemp('gpio');
      for (final n in [6, 1]) {
        final d = Directory('${tmp.path}/gpio$n')..createSync();
        File('${d.path}/value').writeAsStringSync('1\n');
        File('${d.path}/direction').writeAsStringSync('in\n');
      }
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['test', 'test/gpio_sysfs_test.dart'],
        environment: {'GUNDIL_GPIO_SYSFS': tmp.path},
      );
      await tmp.delete(recursive: true);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    }, timeout: const Timeout(Duration(minutes: 2)));
    return;
  }

  test('button press/release is debounced and reported (active low)', () async {
    final value = File('$root/gpio6/value');
    final button = await GpioButton.open(
      line: 6,
      activeLow: true,
      backend: GpioBackend.sysfs,
    );
    final events = <bool>[];
    button.changes.listen(events.add);
    expect(File('$root/gpio6/direction').readAsStringSync(), 'in');

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(events, [false]); // idle (high) = released

    value.writeAsStringSync('0'); // pressed
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(events, [false, true]);

    value.writeAsStringSync('1'); // released
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(events, [false, true, false]);
    await button.close();
  });

  test('LED output writes the value file', () async {
    final led = await GpioOutput.open(line: 1, backend: GpioBackend.sysfs);
    expect(File('$root/gpio1/direction').readAsStringSync(), 'out');
    await led.set(true);
    expect(File('$root/gpio1/value').readAsStringSync(), '1');
    await led.close();
    expect(File('$root/gpio1/value').readAsStringSync(), '0');
  });
}
