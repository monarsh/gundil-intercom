import 'package:flutter/foundation.dart';

import 'package:intercom_core/intercom_core.dart';
import 'platform_bridge.dart';

export 'package:intercom_core/intercom_core.dart';

/// [IntercomCore] as a Flutter [ChangeNotifier], so widgets can rebuild with
/// `ListenableBuilder(listenable: service, ...)`.
class IntercomService extends IntercomCore with ChangeNotifier {
  IntercomService({
    required super.selfId,
    required super.name,
    required super.audio,
    super.preferredPort,
    super.enableDiscovery,
    super.discoveryUdpPort,
    super.sampleRate,
    super.rogerBeep,
    super.autoAnswer,
    super.echoSuppression,
    super.savedPeers,
    super.onSavedPeersChanged,
    super.reconnectInterval,
  }) : super(hooks: const FlutterPlatformHooks()) {
    IntercomCore.log = debugPrint;
  }

  @override
  void changed() {
    super.changed();
    notifyListeners();
  }

  @override
  void onShutdown() => dispose();
}
