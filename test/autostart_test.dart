import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/autostart.dart';

void main() {
  test('Linux autostart entry launches minimized', () {
    final e = Autostart.linuxDesktopEntry('/opt/gundil/gundil_intercom');
    expect(e, startsWith('[Desktop Entry]\n'));
    expect(e, contains('Exec=/opt/gundil/gundil_intercom --minimized\n'));
    expect(e, contains('Name=Gundil Intercom\n'));
  });

  test('paths with spaces are quoted', () {
    final e = Autostart.linuxDesktopEntry('/opt/My Apps/gundil_intercom');
    expect(e, contains('Exec="/opt/My Apps/gundil_intercom" --minimized\n'));
  });
}
