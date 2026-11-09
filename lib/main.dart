import 'package:flutter/material.dart';

import 'src/intercom_service.dart';
import 'src/settings.dart';
import 'src/window_bridge.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final service = IntercomService(
    selfId: settings.deviceId,
    name: settings.name,
    audio: NativeAudioEngine(),
    savedPeers: settings.savedPeers,
    onSavedPeersChanged: (list) => settings.savedPeers = list,
  );
  await service.start();
  if (WindowBridge.supported) {
    await WindowBridge.setTrayEnabled(settings.minimizeToTray);
    _keepTrayTooltipUpdated(service);
  }
  runApp(IntercomApp(service: service, settings: settings));
}

class IntercomApp extends StatelessWidget {
  const IntercomApp({super.key, required this.service, required this.settings});

  final IntercomService service;
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF00897B);
    return MaterialApp(
      title: 'Gundil Intercom',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(service: service, settings: settings),
    );
  }
}

/// Shows the intercom status when hovering the Windows tray icon.
void _keepTrayTooltipUpdated(IntercomService service) {
  String? last;
  void update() {
    final incoming = service.incoming;
    final online = service.onlinePeers.length;
    final String text;
    if (incoming != null) {
      text =
          'Gundil Intercom — ${service.displayName(incoming.peerId)} '
          'is talking';
    } else if (service.transmitting) {
      text =
          'Gundil Intercom — talking to '
          '${service.targetName(service.target)}';
    } else {
      text = 'Gundil Intercom — $online online';
    }
    if (text == last) return;
    last = text;
    WindowBridge.setTooltip(text);
  }

  service.addListener(update);
  update();
}
