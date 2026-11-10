import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// A beacon received from another intercom on the LAN.
class DiscoveryBeacon {
  DiscoveryBeacon({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.tcpPort,
    this.version = 1,
    this.leaving = false,
  });

  final String id;
  final String name;
  final String platform;
  final InternetAddress address;
  final int tcpPort;
  final int version;
  final bool leaving;
}

/// LAN peer discovery via periodic UDP broadcast beacons.
///
/// Each node broadcasts a small JSON datagram every [interval] on
/// [discoveryPort] and listens for everybody else's. Beacons are sent both to
/// the limited broadcast address and to the /24 directed broadcast of every
/// local IPv4 interface, which makes it work on multi-homed Windows machines
/// where 255.255.255.255 only leaves through one adapter.
class Discovery {
  Discovery({
    required this.selfId,
    required this.name,
    required this.tcpPort,
    this.port = discoveryPort,
    this.interval = const Duration(seconds: 2),
  });

  final String selfId;
  String name;
  int tcpPort;
  final int port;
  final Duration interval;

  RawDatagramSocket? _socket;
  Timer? _timer;
  List<InternetAddress> _targets = [InternetAddress('255.255.255.255')];
  int _tick = 0;
  final StreamController<DiscoveryBeacon> _beacons =
      StreamController<DiscoveryBeacon>.broadcast();

  Stream<DiscoveryBeacon> get beacons => _beacons.stream;
  bool get running => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: Platform.isLinux || Platform.isAndroid || Platform.isMacOS,
    );
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event == RawSocketEvent.read) _read(socket);
    });
    _socket = socket;
    await _refreshTargets();
    _announce();
    _timer = Timer.periodic(interval, (_) {
      if (++_tick % 15 == 0) _refreshTargets();
      _announce();
    });
  }

  /// Sends an immediate beacon (e.g. after a name change).
  void announceNow() => _announce();

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final s = _socket;
    if (s != null) {
      _send(s, leaving: true);
      s.close();
    }
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _beacons.close();
  }

  Future<void> _refreshTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {}
    _targets = targets.map(InternetAddress.new).toList();
  }

  void _announce() {
    final s = _socket;
    if (s != null) _send(s);
  }

  void _send(RawDatagramSocket s, {bool leaving = false}) {
    final data = utf8.encode(
      jsonEncode({
        'app': 'p2p-intercom',
        'v': protocolVersion,
        'id': selfId,
        'name': name,
        'platform': Platform.operatingSystem,
        'port': tcpPort,
        if (leaving) 'bye': true,
      }),
    );
    for (final t in _targets) {
      try {
        s.send(data, t, port);
      } catch (_) {
        // Interface may have gone away; ignore.
      }
    }
  }

  void _read(RawDatagramSocket s) {
    Datagram? d;
    while ((d = s.receive()) != null) {
      final beacon = parseBeacon(d!.data, d.address, selfId);
      if (beacon != null && !_beacons.isClosed) _beacons.add(beacon);
    }
  }

  /// Parses a beacon datagram; returns null for foreign/invalid/own packets.
  static DiscoveryBeacon? parseBeacon(
    List<int> data,
    InternetAddress from,
    String selfId,
  ) {
    try {
      final m = jsonDecode(utf8.decode(data));
      if (m is! Map || m['app'] != 'p2p-intercom') return null;
      final id = m['id'];
      final port = m['port'];
      if (id is! String || id == selfId || port is! int) return null;
      if (port <= 0 || port > 65535) return null;
      return DiscoveryBeacon(
        id: id,
        name: (m['name'] as String?) ?? 'Unknown',
        platform: (m['platform'] as String?) ?? '?',
        address: from,
        tcpPort: port,
        version: (m['v'] as int?) ?? 1,
        leaving: m['bye'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
