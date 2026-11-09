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

  final List<ChatMessage> messages = [];
  int unread = 0;

  static const Duration beaconTimeout = Duration(seconds: 7);

  bool get online {
    if (connected) return true;
    final b = lastBeacon;
    return b != null && DateTime.now().difference(b) < beaconTimeout;
  }

  String get endpoint => '${address.address}:$port';
}

class ChatMessage {
  ChatMessage({required this.text, required this.mine, DateTime? time})
    : time = time ?? DateTime.now();
  final String text;
  final bool mine;
  final DateTime time;
}

enum CallState { idle, outgoing, incoming, active }

class CallInfo {
  CallInfo({
    required this.peerId,
    required this.state,
    required this.sampleRate,
  });
  final String peerId;
  CallState state;
  final int sampleRate;
  DateTime? startedAt;
}
