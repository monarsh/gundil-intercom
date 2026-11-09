import 'dart:typed_data';

import 'package:intercom_core/node.dart';
import 'package:test/test.dart';

void main() {
  group('NodeConfig', () {
    test('parses key = value lines with comments', () {
      final m = NodeConfig.parse('''
# comment
name = Gate   # trailing comment
target=Office-PC
ptt-gpio = 6

peers = 192.168.1.2, 192.168.1.3:5000
''');
      expect(m['name'], 'Gate');
      expect(m['target'], 'Office-PC');
      final c = NodeConfig(m);
      expect(c.integer('ptt-gpio'), 6);
      expect(c.list('peers'), ['192.168.1.2', '192.168.1.3:5000']);
      expect(c.flag('roger-beep', fallback: true), isTrue);
    });

    test('command line overrides the file; bad numbers are reported', () {
      final c = NodeConfig.load([
        '--config=/dev/null',
        '--ptt-gpio=x',
        '--help',
      ]);
      expect(c.help, isTrue);
      expect(() => c.integer('ptt-gpio'), throwsFormatException);
    });
  });

  group('InputKey.parseEvent', () {
    Uint8List event(int size, int type, int code, int value) {
      final b = Uint8List(size);
      final d = ByteData.sublistView(b);
      final t = size - 8;
      d.setUint16(t, type, Endian.little);
      d.setUint16(t + 2, code, Endian.little);
      d.setInt32(t + 4, value, Endian.little);
      return b;
    }

    for (final size in [16, 24]) {
      test('$size-byte events (${size == 16 ? '32' : '64'}-bit)', () {
        final down = InputKey.parseEvent(event(size, 1, 57, 1), 0, size)!;
        expect(down.code, 57);
        expect(down.value, 1);
        final up = InputKey.parseEvent(event(size, 1, 57, 0), 0, size)!;
        expect(up.value, 0);
        // EV_SYN and other types are ignored.
        expect(InputKey.parseEvent(event(size, 0, 0, 0), 0, size), isNull);
      });
    }
  });
}
