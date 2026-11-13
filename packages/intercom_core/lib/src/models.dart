import 'dart:io';

import 'protocol.dart';

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

  /// Addresses the peer was recently seen at, newest first: it can be
  /// reachable several ways (LAN, Tailscale, WireGuard, ...), and after a
  /// network switch only some of them still work. Tried in turn when
  /// connecting.
  final List<(InternetAddress, int)> endpoints = [];

  /// Remembers [address]:[port] as the newest way to reach the peer.
  void noteEndpoint(InternetAddress address, int port) {
    endpoints.removeWhere((e) => e.$1 == address && e.$2 == port);
    endpoints.insert(0, (address, port));
    if (endpoints.length > maxEndpoints) endpoints.removeLast();
  }

  static const int maxEndpoints = 4;

  /// The IPv4 addresses the peer says it has (its HELLO lists them), e.g.
  /// LAN and VPN: tried too when its usual address doesn't answer.
  List<InternetAddress> announced = const [];

  /// Last time we heard a discovery beacon from this peer.
  DateTime? lastBeacon;

  /// Whether a live TCP connection to the peer currently exists.
  bool connected = false;

  /// Protocol version the peer reported (0 = unknown yet).
  int version = 0;

  /// The peer can show camera video (the app; not the headless node).
  bool video = false;

  /// Too old to connect: no encryption (the user must update that device).
  bool get outdated => version != 0 && version < minConversationVersion;

  /// The last connection failed because it uses another intercom password.
  bool wrongPassword = false;

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
    this.altHost = '',
  });

  /// Stable local identifier of this list entry.
  final String key;

  /// Custom display name; empty means "use the name the peer announces".
  String label;

  /// IP address or hostname used to (re)connect (the primary one).
  String host;
  int port;

  /// Optional alternate (secondary) address of the same device, e.g. its
  /// VPN / Tailscale address next to the LAN one. Both are tried; whichever
  /// answers is used. Empty = none.
  String altHost;

  /// Primary first, then the alternate.
  List<String> get hosts => [host, if (altHost.isNotEmpty) altHost];

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
    if (altHost.isNotEmpty) 'alt': altHost,
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
      altHost: (json['alt'] as String?) ?? '',
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

  /// The alternate address of a saved peer ('' = none).
  String get altHost => saved?.altHost ?? '';
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

/// State of one peer in the current conversation.
enum MemberState {
  /// We asked them to join; waiting for their answer.
  calling,

  /// They asked us; waiting for us to accept (auto-answer off).
  ringing,

  /// Two-way audio is flowing.
  connected,
}

/// The current two-way audio line (one at a time).
class Conversation {
  Conversation({required this.group, required this.outgoing});

  /// Started with "Everyone" (we are the hub and hear all members mixed).
  final bool group;

  /// We started it.
  final bool outgoing;

  final Map<String, MemberState> members = {};

  /// When the first member connected.
  DateTime? connectedAt;

  /// Last time anything was heard from each member (liveness).
  final Map<String, DateTime> lastHeard = {};

  final Map<String, DateTime> invitedAt = {};

  Iterable<String> get connected => members.entries
      .where((e) => e.value == MemberState.connected)
      .map((e) => e.key);
  Iterable<String> get ringing => members.entries
      .where((e) => e.value == MemberState.ringing)
      .map((e) => e.key);
  Iterable<String> get calling => members.entries
      .where((e) => e.value == MemberState.calling)
      .map((e) => e.key);

  bool get isConnected => connected.isNotEmpty;
}
