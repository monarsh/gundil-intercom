import 'package:flutter/foundation.dart';

import 'platform_bridge.dart';

/// Kind of audio output on Android.
enum AudioRouteType { speaker, earpiece, bluetooth, wired, other }

/// One selectable audio output (e.g. "Speaker", "Galaxy Buds").
class AudioRoute {
  const AudioRoute({required this.id, required this.type, required this.name});

  final String id;
  final AudioRouteType type;
  final String name;

  static AudioRoute? fromMap(Object? m) {
    if (m is! Map) return null;
    final id = m['id'], name = m['name'];
    if (id is! String) return null;
    return AudioRoute(
      id: id,
      type: switch (m['type']) {
        'speaker' => AudioRouteType.speaker,
        'earpiece' => AudioRouteType.earpiece,
        'bluetooth' => AudioRouteType.bluetooth,
        'wired' => AudioRouteType.wired,
        _ => AudioRouteType.other,
      },
      name: name is String && name.isNotEmpty ? name : id,
    );
  }
}

/// Android audio-output picker state: available outputs and the current
/// one, kept in sync with the phone (headset connected / removed, ...).
class AudioRoutes extends ChangeNotifier {
  AudioRoutes() {
    PlatformBridge.onAudioRoutesChanged(apply);
  }

  /// The app-wide instance (only meaningful on Android).
  static final AudioRoutes instance = AudioRoutes();

  List<AudioRoute> _routes = const [];
  String? _currentId;
  bool _active = false;

  List<AudioRoute> get routes => _routes;

  /// Call audio is running (outputs only matter then).
  bool get active => _active;

  AudioRoute? get current =>
      _routes.where((r) => r.id == _currentId).firstOrNull;

  /// Applies a state map from Android.
  @visibleForTesting
  void apply(Map<Object?, Object?> state) {
    final list = state['routes'];
    _routes = list is List
        ? list.map(AudioRoute.fromMap).whereType<AudioRoute>().toList()
        : const [];
    final cur = state['current'];
    _currentId = cur is String ? cur : null;
    _active = state['active'] == true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final s = await PlatformBridge.getAudioRoutes();
    if (s != null) apply(s);
  }

  Future<void> select(AudioRoute route) async {
    final s = await PlatformBridge.setAudioRoute(route.id);
    if (s != null) apply(s);
  }
}
