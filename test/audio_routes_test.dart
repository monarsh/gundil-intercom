import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/audio_routes.dart';
import 'package:p2p_intercom/ui/intercom_panel.dart';

/// What Android sends with a Bluetooth headset connected (Android 12+ ids).
final Map<Object?, Object?> phoneWithBuds = {
  'active': true,
  'current': '41',
  'routes': [
    {'id': '41', 'type': 'bluetooth', 'name': 'Galaxy Buds2'},
    {'id': '2', 'type': 'speaker', 'name': 'Speaker'},
    {'id': '1', 'type': 'earpiece', 'name': 'Phone (earpiece)'},
  ],
};

void main() {
  test('parses routes and the current output', () {
    final r = AudioRoutes()..apply(phoneWithBuds);
    expect(r.active, isTrue);
    expect(r.routes.map((e) => e.type), [
      AudioRouteType.bluetooth,
      AudioRouteType.speaker,
      AudioRouteType.earpiece,
    ]);
    expect(r.current!.name, 'Galaxy Buds2');

    r.apply({'active': false, 'current': null, 'routes': []});
    expect(r.current, isNull);
    expect(r.routes, isEmpty);
  });

  test('ignores malformed entries', () {
    final r = AudioRoutes()
      ..apply({
        'current': 'wired',
        'routes': [
          {'id': 'wired', 'type': 'wired', 'name': ''},
          {'type': 'speaker'}, // no id
          'junk',
        ],
      });
    expect(r.routes.single.name, 'wired'); // empty name falls back to id
    expect(r.current!.type, AudioRouteType.wired);
  });

  testWidgets('button shows the current output; sheet lists all', (
    tester,
  ) async {
    AudioRoutes.instance.apply(phoneWithBuds);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: AudioOutputButton())),
      ),
    );
    expect(find.text('Galaxy Buds2'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_audio), findsOneWidget);

    await tester.tap(find.byType(AudioOutputButton));
    await tester.pumpAndSettle();
    expect(find.text('Audio output'), findsOneWidget);
    expect(find.text('Speaker'), findsOneWidget);
    expect(find.text('Phone (earpiece)'), findsOneWidget);
    expect(
      find.text('Bluetooth headset (uses its microphone)'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // Android reports a switch to the speaker: the button follows.
    AudioRoutes.instance.apply({...phoneWithBuds, 'current': '2'});
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AudioOutputButton, 'Speaker'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });
}
