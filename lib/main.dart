import 'dart:io';

import 'package:flutter/material.dart';

import 'src/intercom_service.dart';
import 'src/platform_bridge.dart';
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
    autoAnswer: settings.autoAnswer,
    videoReceive: true,
    password: settings.password,
    speakerVolume: settings.speakerVolume,
    micVolume: settings.micVolume,
    echoSuppression: settings.echoSuppression,
    savedPeers: settings.savedPeers,
    onSavedPeersChanged: (list) => settings.savedPeers = list,
  );
  await service.start();
  if (WindowBridge.supported) {
    await WindowBridge.setTrayEnabled(settings.minimizeToTray);
  }
  if (WindowBridge.supported || Platform.isAndroid) {
    _mirrorStatusOutsideApp(service);
  }
  // Remember volume changes (sliders in the call screen / app bar).
  service.addListener(() {
    if (settings.speakerVolume != service.speakerVolume) {
      settings.speakerVolume = service.speakerVolume;
    }
    if (settings.micVolume != service.micVolume) {
      settings.micVolume = service.micVolume;
    }
  });
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

/// Keeps people informed when they aren't looking at the app:
/// * Windows: tray tooltip ("Gate is speaking") and a notification when a
///   line opens or someone rings while the window is hidden;
/// * Android: the background-mode notification ("Connected with Gate").
void _mirrorStatusOutsideApp(IntercomService service) {
  String? lastTooltip;
  String? lastAndroid;
  String names(Iterable<String> ids) => ids.map(service.displayName).join(', ');

  void update() {
    final conv = service.conversation;
    final String tooltip;
    final String android;
    if (conv == null) {
      tooltip = 'Gundil Intercom — ${service.onlinePeers.length} online';
      android = '';
    } else if (service.ringing) {
      tooltip = 'Gundil Intercom — ${names(conv.ringing)} wants to talk';
      android = '${names(conv.ringing)} wants to talk';
    } else if (conv.isConnected) {
      final speakers = service.speakers;
      tooltip = speakers.isNotEmpty
          ? 'Gundil Intercom — ${names(speakers)} speaking'
          : 'Gundil Intercom — connected with ${names(conv.connected)}';
      android = 'Connected with ${names(conv.connected)}';
    } else {
      tooltip = 'Gundil Intercom — connecting…';
      android = 'Connecting…';
    }
    if (WindowBridge.supported && tooltip != lastTooltip) {
      lastTooltip = tooltip;
      WindowBridge.setTooltip(tooltip);
    }
    if (Platform.isAndroid && android != lastAndroid) {
      lastAndroid = android;
      PlatformBridge.setStatus(
        android,
        android.isEmpty ? '' : 'Tap to open Gundil Intercom',
      );
    }
  }

  service.addListener(update);
  update();

  if (WindowBridge.supported) {
    service.events.listen((e) {
      switch (e.kind) {
        case IntercomEventKind.connected:
          WindowBridge.notify('Gundil Intercom', '${e.message} — line open');
        case IntercomEventKind.ringing:
          WindowBridge.notify('Gundil Intercom', e.message);
        case IntercomEventKind.disconnected:
        case IntercomEventKind.info:
          break;
      }
    });
  }
}
