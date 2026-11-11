import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/ui/volume_sheet.dart';

void main() {
  testWidgets('volume sliders change the volume; 100% resets', (t) async {
    final service = IntercomService(
      selfId: 'me',
      name: 'Me',
      audio: FakeAudioEngine(),
      enableDiscovery: false,
    );
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VolumeControls(service: service)),
      ),
    );
    expect(find.text('100%'), findsWidgets);

    // Drag the speaker slider all the way left: 0%.
    final speaker = find.byType(Slider).first;
    await t.drag(speaker, const Offset(-400, 0));
    await t.pump();
    expect(service.speakerVolume, 0);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    // Microphone all the way right: 200%, with the distortion hint.
    await t.drag(find.byType(Slider).last, const Offset(400, 0));
    await t.pump();
    expect(service.micVolume, IntercomCore.maxVolume);
    expect(find.textContaining('may distort'), findsOneWidget);

    // The "100%" buttons reset each slider.
    await t.tap(find.widgetWithText(TextButton, '100%').first);
    await t.tap(find.widgetWithText(TextButton, '100%').last);
    await t.pump();
    expect(service.speakerVolume, 1);
    expect(service.micVolume, 1);
  });
}
