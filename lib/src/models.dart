import 'dart:io';

/// A remote intercom node.
class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    this.manual = false,
  });

  final String id;
  String name;
  String platform;
  InternetAddress address;
  int port;

  /// Added by hand (IP address) rather than discovered via broadcast.
  bool manual;

  /// Last time we heard a discovery beacon from this peer.
  DateTime? lastBeacon;

  /// Whether a live TCP connection to the peer currently exists.
  bool connected = false;

  static const Duration beaconTimeout = Duration(seconds: 7);

  bool get online {
    if (connected) return true;
    final b = lastBeacon;
    return b != null && DateTime.now().difference(b) < beaconTimeout;
  }

  String get endpoint => '${address.address}:$port';
}

/// Who push-to-talk transmits to.
sealed class TalkTarget {
  const TalkTarget();
}

/// Every online peer at once (group call / paging).
class EveryoneTarget extends TalkTarget {
  const EveryoneTarget();
  @override
  bool operator ==(Object other) => other is EveryoneTarget;
  @override
  int get hashCode => 0;
}

/// A single peer.
class PeerTarget extends TalkTarget {
  const PeerTarget(this.peerId);
  final String peerId;
  @override
  bool operator ==(Object other) =>
      other is PeerTarget && other.peerId == peerId;
  @override
  int get hashCode => peerId.hashCode;
}

/// A transmission we are currently receiving.
class IncomingTalk {
  IncomingTalk({
    required this.peerId,
    required this.sampleRate,
    required this.group,
  });
  final String peerId;
  final int sampleRate;

  /// Sent to everyone rather than just us.
  final bool group;
  final DateTime startedAt = DateTime.now();
  DateTime lastAudio = DateTime.now();
}
