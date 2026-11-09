import 'package:flutter/material.dart';

import 'src/audio_engine.dart';
import 'src/intercom_service.dart';
import 'src/settings.dart';
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
