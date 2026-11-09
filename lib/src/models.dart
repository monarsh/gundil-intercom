import 'dart:io';

/// A remote intercom node.
class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
  });

  final String id;
  String name;
  String platform;
  InternetAddress address;
  int port;

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

/// A peer the user saved (added by IP, or a discovered peer they renamed).
/// Saved peers are persisted and stay in the list across app restarts, even
/// while offline.
class SavedPeer {
  SavedPeer({
    required this.key,
    required this.host,
    required this.port,
    this.label = '',
    this.peerId,
    this.platform = '?',
  });

  /// Stable local identifier of this list entry.
  final String key;

  /// Custom display name; empty means "use the name the peer announces".
  String label;

  /// IP address or hostname used to (re)connect.
  String host;
  int port;

  /// The remote device id, learned on first successful connection.
  String? peerId;

  /// Last known OS of the peer (for the icon while it's offline).
  String platform;

  String get endpoint => '$host:$port';

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'host': host,
    'port': port,
    if (peerId != null) 'peerId': peerId,
    'platform': platform,
  };

  static SavedPeer? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'], host = json['host'], port = json['port'];
    if (key is! String || host is! String || port is! int) return null;
    return SavedPeer(
      key: key,
      host: host,
      port: port,
      label: (json['label'] as String?) ?? '',
      peerId: json['peerId'] as String?,
      platform: (json['platform'] as String?) ?? '?',
    );
  }
}

/// One row of the peer list: a saved peer, a live (discovered/connected)
/// peer, or both when a saved peer is currently reachable.
class PeerEntry {
  PeerEntry({this.saved, this.live}) : assert(saved != null || live != null);

  final SavedPeer? saved;
  final Peer? live;

  String get key => saved?.key ?? 'live:${live!.id}';
  bool get isSaved => saved != null;

  /// Remote device id, if known. Needed to talk to the peer.
  String? get peerId => live?.id ?? saved?.peerId;

  String get name {
    final label = saved?.label.trim() ?? '';
    if (label.isNotEmpty) return label;
    return live?.name ?? saved!.host;
  }

  bool get online => live?.online ?? false;
  String get platform => live?.platform ?? saved!.platform;

  String get host {
    final l = live;
    if (l != null && (l.online || saved == null)) return l.address.address;
    return saved!.host;
  }

  int get port => saved?.port ?? live!.port;
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
