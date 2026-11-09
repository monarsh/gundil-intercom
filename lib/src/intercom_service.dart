import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'discovery.dart';
import 'models.dart';
import 'peer_connection.dart';
import 'platform_bridge.dart';
import 'protocol.dart';

/// Notification for the UI (errors, call ended reasons, ...).
class IntercomEvent {
  IntercomEvent(this.message, {this.error = false});
  final String message;
  final bool error;
}

/// The heart of the intercom: owns the TCP server, the connections to every
/// peer, LAN discovery, the single active call and the audio pump.
class IntercomService extends ChangeNotifier {
  IntercomService({
    required this.selfId,
    required String name,
    required this.audio,
    this.preferredPort = defaultTcpPort,
    this.enableDiscovery = true,
    this.discoveryUdpPort = discoveryPort,
    this.sampleRate = defaultSampleRate,
    bool autoAnswer = false,
  }) : _name = name, // ignore: prefer_initializing_formals
       _autoAnswer = autoAnswer; // ignore: prefer_initializing_formals

  final String selfId;
  final AudioEngine audio;
  final int preferredPort;
  final bool enableDiscovery;
  final int discoveryUdpPort;
  final int sampleRate;

  /// Audio frame duration sent over the wire.
  static const Duration frameDuration = Duration(milliseconds: 20);

  /// Playback queue above which we drop audio to keep latency low.
  static const Duration maxPlaybackLatency = Duration(milliseconds: 250);

  /// Unanswered outgoing calls are cancelled after this long.
  static const Duration ringTimeout = Duration(seconds: 30);

  String _name;
  bool _autoAnswer;
  bool _muted = false;
  bool _speaker = true;
  double _micLevel = 0;

  ServerSocket? _server;
  Discovery? _discovery;
  Timer? _housekeeping;
  Timer? _audioPump;
  Timer? _ringTimer;

  final Map<String, Peer> _peers = {};
  final Map<String, PeerConnection> _links = {};
  final Set<PeerConnection> _allConnections = {};
  final Map<String, Future<PeerConnection>> _connecting = {};

  CallInfo? _call;
  PeerConnection? _callLink;

  String? _selectedPeerId;
  bool _shutDown = false;

  final StreamController<IntercomEvent> _events =
      StreamController<IntercomEvent>.broadcast();

  // ---------------------------------------------------------------- getters

  String get name => _name;
  bool get autoAnswer => _autoAnswer;
  bool get muted => _muted;
  bool get speaker => _speaker;
  double get micLevel => _micLevel;
  int? get listenPort => _server?.port;
  bool get discoveryRunning => _discovery?.running ?? false;
  CallInfo? get call => _call;
  Stream<IntercomEvent> get events => _events.stream;
  String? get selectedPeerId => _selectedPeerId;
  Peer? get selectedPeer =>
      _selectedPeerId == null ? null : _peers[_selectedPeerId];
  Peer? peer(String id) => _peers[id];

  /// Peers sorted: online first, then by name.
  List<Peer> get peers {
    final list = _peers.values.toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  // -------------------------------------------------------------- lifecycle

  Future<void> start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // Port taken (e.g. second instance on the same machine): use any port.
      // Discovery advertises the real port, so peers still find us.
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(
      (s) => _adopt(PeerConnection(s, outgoing: false)),
      onError: (Object e) => _emit('Server error: $e', error: true),
    );

    if (enableDiscovery) {
      await PlatformBridge.acquireMulticastLock();
      final d = Discovery(
        selfId: selfId,
        name: _name,
        tcpPort: _server!.port,
        port: discoveryUdpPort,
      );
      d.beacons.listen(_onBeacon);
      try {
        await d.start();
        _discovery = d;
      } on SocketException catch (e) {
        _emit(
          'LAN discovery unavailable (${e.message}). '
          'Add peers manually by IP.',
          error: true,
        );
      }
    }

    _housekeeping = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
  }

  /// Hangs up, closes every socket and releases resources.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    if (_call != null) hangup();
    _housekeeping?.cancel();
    _ringTimer?.cancel();
    _stopAudio();
    await _discovery?.dispose();
    await PlatformBridge.releaseMulticastLock();
    for (final c in _allConnections.toList()) {
      await c.close();
    }
    await _server?.close();
    await _events.close();
    dispose();
  }

  // ----------------------------------------------------------------- config

  set name(String value) {
    final v = value.trim();
    if (v.isEmpty || v == _name) return;
    _name = v;
    _discovery?.name = v;
    _discovery?.announceNow();
    for (final c in _links.values) {
      c.send(_hello());
    }
    notifyListeners();
  }

  set autoAnswer(bool v) {
    _autoAnswer = v;
    notifyListeners();
  }

  void toggleMute() {
    _muted = !_muted;
    if (_muted) _micLevel = 0;
    notifyListeners();
  }

  void toggleSpeaker() {
    _speaker = !_speaker;
    PlatformBridge.setSpeaker(_speaker);
    notifyListeners();
  }

  void selectPeer(String? id) {
    _selectedPeerId = id;
    final p = id == null ? null : _peers[id];
    if (p != null) p.unread = 0;
    notifyListeners();
  }

  // ---------------------------------------------------------------- peers

  /// Adds a peer by IP address/hostname (for networks that block broadcast).
  Future<Peer> addManualPeer(String host, {int port = defaultTcpPort}) async {
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) throw SocketException('Cannot resolve $host');
    final conn = await PeerConnection.connect(addresses.first, port);
    final helloSeen = Completer<String>();
    _adopt(
      conn,
      onHello: (id) {
        if (!helloSeen.isCompleted) helloSeen.complete(id);
      },
    );
    final id = await helloSeen.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        conn.close();
        throw TimeoutException('$host:$port is not an intercom peer');
      },
    );
    final p = _peers[id]!;
    p.manual = true;
    p.address = addresses.first;
    p.port = port;
    notifyListeners();
    return p;
  }

  void removePeer(String id) {
    if (_call?.peerId == id) hangup();
    _links.remove(id)?.close();
    _peers.remove(id);
    if (_selectedPeerId == id) _selectedPeerId = null;
    notifyListeners();
  }

  void _onBeacon(DiscoveryBeacon b) {
    if (b.leaving) {
      final p = _peers[b.id];
      if (p != null) {
        p.lastBeacon = null;
        notifyListeners();
      }
      return;
    }
    final p = _upsertPeer(
      id: b.id,
      name: b.name,
      platform: b.platform,
      address: b.address,
      port: b.tcpPort,
    );
    p.lastBeacon = DateTime.now();
  }

  Peer _upsertPeer({
    required String id,
    required String name,
    required String platform,
    required InternetAddress address,
    required int port,
  }) {
    final existing = _peers[id];
    if (existing != null) {
      final changed =
          existing.name != name ||
          existing.address != address ||
          existing.port != port;
      existing
        ..name = name
        ..platform = platform
        ..address = address
        ..port = port;
      if (changed) notifyListeners();
      return existing;
    }
    final p = Peer(
      id: id,
      name: name,
      platform: platform,
      address: address,
      port: port,
    );
    _peers[id] = p;
    notifyListeners();
    return p;
  }

  // ------------------------------------------------------------ connections

  Frame _hello() => Frame.json(MessageType.hello, {
    'id': selfId,
    'name': _name,
    'platform': Platform.operatingSystem,
    'port': _server?.port ?? preferredPort,
    'v': protocolVersion,
  });

  void _adopt(PeerConnection c, {void Function(String id)? onHello}) {
    _allConnections.add(c);
    c.send(_hello());
    c.frames.listen((f) => _onFrame(c, f, onHello));
    c.done.then((_) => _onConnectionClosed(c));
  }

  Future<PeerConnection> _linkTo(Peer p) {
    final existing = _links[p.id];
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return _connecting[p.id] ??= () async {
      try {
        final conn = await PeerConnection.connect(p.address, p.port);
        conn.remoteId = p.id;
        _links[p.id] = conn;
        p.connected = true;
        _adopt(conn);
        return conn;
      } finally {
        _connecting.remove(p.id);
      }
    }();
  }

  void _onConnectionClosed(PeerConnection c) {
    _allConnections.remove(c);
    final id = c.remoteId;
    if (id != null && identical(_links[id], c)) {
      _links.remove(id);
      // Another connection to the same peer may still be alive.
      final alt = _allConnections
          .where((o) => o.remoteId == id && !o.isClosed)
          .firstOrNull;
      if (alt != null) _links[id] = alt;
      _peers[id]?.connected = alt != null;
    }
    if (identical(c, _callLink)) {
      _endCall('Connection to ${_peerName(id)} lost', error: true);
    }
    notifyListeners();
  }

  void _onFrame(PeerConnection c, Frame f, void Function(String id)? onHello) {
    try {
      _handleFrame(c, f, onHello);
    } catch (e) {
      debugPrint('Bad ${f.type.name} frame: $e');
    }
  }

  void _handleFrame(
    PeerConnection c,
    Frame f,
    void Function(String id)? onHello,
  ) {
    if (f.type == MessageType.hello) {
      final m = f.json;
      final id = m['id'];
      if (id is! String || id == selfId) {
        c.close();
        return;
      }
      c.remoteId = id;
      final p = _upsertPeer(
        id: id,
        name: (m['name'] as String?) ?? 'Unknown',
        platform: (m['platform'] as String?) ?? '?',
        address: c.remoteAddress,
        port: (m['port'] as int?) ?? defaultTcpPort,
      );
      final current = _links[id];
      if (current == null || current.isClosed) _links[id] = c;
      p.connected = true;
      onHello?.call(id);
      notifyListeners();
      return;
    }

    final id = c.remoteId;
    if (id == null) return; // Must say hello first.
    final call = _call;

    switch (f.type) {
      case MessageType.hello:
        break;
      case MessageType.ping:
        c.send(Frame.empty(MessageType.pong));
      case MessageType.pong:
        break;
      case MessageType.text:
        final text = f.json['text'];
        final p = _peers[id];
        if (text is String && p != null) {
          p.messages.add(ChatMessage(text: text, mine: false));
          if (_selectedPeerId != id) p.unread++;
          notifyListeners();
        }
      case MessageType.callRequest:
        final rate = (f.json['sampleRate'] as int?) ?? defaultSampleRate;
        if (call != null) {
          c.send(Frame.json(MessageType.callReject, {'reason': 'busy'}));
          return;
        }
        _call = CallInfo(
          peerId: id,
          state: CallState.incoming,
          sampleRate: rate,
        );
        _callLink = c;
        _ringTimer?.cancel();
        _ringTimer = Timer(ringTimeout, () {
          if (_call?.state == CallState.incoming) {
            reject();
            _emit('Missed call from ${_peerName(id)}');
          }
        });
        notifyListeners();
        if (_autoAnswer) accept();
      case MessageType.callAccept:
        if (call != null &&
            call.peerId == id &&
            call.state == CallState.outgoing) {
          _callLink = c;
          _goActive();
        }
      case MessageType.callReject:
        if (call != null &&
            call.peerId == id &&
            call.state != CallState.active) {
          final reason = f.json['reason'];
          _endCall(
            reason == 'busy'
                ? '${_peerName(id)} is busy'
                : '${_peerName(id)} declined the call',
          );
        }
      case MessageType.hangup:
        if (call != null && call.peerId == id) {
          final missed = call.state == CallState.incoming;
          _endCall(
            missed
                ? 'Missed call from ${_peerName(id)}'
                : '${_peerName(id)} ended the call',
          );
        }
      case MessageType.audio:
        if (call != null &&
            call.peerId == id &&
            call.state == CallState.active) {
          _playIncoming(bytesToPcm(f.payload));
        }
    }
  }

  // ------------------------------------------------------------------ chat

  Future<void> sendText(String peerId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final p = _peers[peerId];
    if (p == null) return;
    final conn = await _linkTo(p);
    conn.send(Frame.json(MessageType.text, {'text': t}));
    p.messages.add(ChatMessage(text: t, mine: true));
    notifyListeners();
  }

  // ----------------------------------------------------------------- calls

  /// Calls [peerId]. Any existing call is ended first, which is how the user
  /// switches between peers.
  Future<void> callPeer(String peerId) async {
    final p = _peers[peerId];
    if (p == null) return;
    if (_call != null) hangup();
    if (!await PlatformBridge.requestMicrophone()) {
      _emit('Microphone permission denied', error: true);
      return;
    }
    _call = CallInfo(
      peerId: peerId,
      state: CallState.outgoing,
      sampleRate: sampleRate,
    );
    notifyListeners();
    try {
      final conn = await _linkTo(p);
      if (_call?.peerId != peerId) return; // Cancelled while connecting.
      _callLink = conn;
      conn.send(
        Frame.json(MessageType.callRequest, {'sampleRate': sampleRate}),
      );
      _ringTimer?.cancel();
      _ringTimer = Timer(ringTimeout, () {
        if (_call?.state == CallState.outgoing && _call?.peerId == peerId) {
          hangup();
          _emit('${p.name} did not answer');
        }
      });
    } catch (e) {
      if (_call?.peerId == peerId) {
        _endCall('Could not reach ${p.name}: ${_short(e)}', error: true);
      }
    }
  }

  Future<void> accept() async {
    final call = _call;
    final link = _callLink;
    if (call == null || call.state != CallState.incoming || link == null) {
      return;
    }
    if (!await PlatformBridge.requestMicrophone()) {
      _emit('Microphone permission denied', error: true);
      reject();
      return;
    }
    if (!identical(_call, call)) return;
    link.send(Frame.empty(MessageType.callAccept));
    _goActive();
  }

  void reject() {
    final call = _call;
    if (call == null || call.state != CallState.incoming) return;
    _callLink?.send(Frame.json(MessageType.callReject, {'reason': 'declined'}));
    _endCall(null);
  }

  void hangup() {
    if (_call == null) return;
    if (_call!.state == CallState.incoming) {
      reject();
      return;
    }
    _callLink?.send(Frame.empty(MessageType.hangup));
    _endCall(null);
  }

  void _goActive() {
    final call = _call!;
    _ringTimer?.cancel();
    call
      ..state = CallState.active
      ..startedAt = DateTime.now();
    try {
      _startAudio(call.sampleRate);
    } catch (e) {
      _callLink?.send(Frame.empty(MessageType.hangup));
      _endCall('Audio device error: ${_short(e)}', error: true);
      return;
    }
    notifyListeners();
  }

  void _endCall(String? reason, {bool error = false}) {
    _ringTimer?.cancel();
    _stopAudio();
    _call = null;
    _callLink = null;
    if (reason != null) _emit(reason, error: error);
    notifyListeners();
  }

  // ----------------------------------------------------------------- audio

  void _startAudio(int rate) {
    PlatformBridge.startCallAudio(speaker: _speaker);
    audio.init(rate);
    audio.start();
    _audioPump?.cancel();
    _audioPump = Timer.periodic(frameDuration, (_) => _pumpMic());
  }

  void _stopAudio() {
    if (_audioPump == null) return;
    _audioPump?.cancel();
    _audioPump = null;
    _micLevel = 0;
    try {
      audio.stop();
    } catch (_) {}
    PlatformBridge.stopCallAudio();
  }

  int _levelTick = 0;

  void _pumpMic() {
    final link = _callLink;
    if (link == null || _call?.state != CallState.active) return;
    final samples = audio.readCaptured();
    if (samples.isEmpty) return;
    if (!_muted) {
      link.send(Frame(MessageType.audio, pcmToBytes(samples)));
      _micLevel = rmsLevel(samples);
    }
    // Refresh the level meter ~10x per second.
    if (++_levelTick % 5 == 0) notifyListeners();
  }

  void _playIncoming(Int16List samples) {
    final cap = audio.sampleRate * maxPlaybackLatency.inMilliseconds ~/ 1000;
    if (audio.queued > cap) audio.flushPlayback();
    audio.play(samples);
  }

  /// RMS level of [samples] normalised to 0..1 on a perceptual (dB) scale.
  static double rmsLevel(Int16List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples.length) / 32768.0;
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10; // -inf..0
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  // --------------------------------------------------------------- helpers

  String _peerName(String? id) =>
      (id == null ? null : _peers[id]?.name) ?? 'Peer';

  void _emit(String message, {bool error = false}) {
    if (!_events.isClosed) _events.add(IntercomEvent(message, error: error));
  }

  static String _short(Object e) {
    if (e is SocketException) return e.osError?.message ?? e.message;
    if (e is TimeoutException) return e.message ?? 'timed out';
    return e.toString();
  }
}
