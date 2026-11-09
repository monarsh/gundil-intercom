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

/// Notification for the UI (errors and short info messages).
class IntercomEvent {
  IntercomEvent(this.message, {this.error = false});
  final String message;
  final bool error;
}

/// Walkie-talkie style intercom.
///
/// There is no call setup: while push-to-talk is held, microphone audio is
/// streamed over TCP to the selected peer (or to everyone) and played on
/// their speaker straight away. Releasing the button ends the transmission.
/// The channel is half-duplex: incoming audio is ignored while we transmit,
/// and only one incoming talker is played at a time.
class IntercomService extends ChangeNotifier {
  IntercomService({
    required this.selfId,
    required String name,
    required this.audio,
    this.preferredPort = defaultTcpPort,
    this.enableDiscovery = true,
    this.discoveryUdpPort = discoveryPort,
    this.sampleRate = defaultSampleRate,
    this.rogerBeep = true,
  }) : _name = name; // ignore: prefer_initializing_formals

  final String selfId;
  final AudioEngine audio;
  final int preferredPort;
  final bool enableDiscovery;
  final int discoveryUdpPort;
  final int sampleRate;

  /// Play a short "over" chirp when a remote transmission ends.
  final bool rogerBeep;

  /// How often captured audio is sent.
  static const Duration frameDuration = Duration(milliseconds: 20);

  /// Playback queue above which we drop audio to keep latency low.
  static const Duration maxPlaybackLatency = Duration(milliseconds: 250);

  /// An incoming transmission with no audio for this long is considered over
  /// (the sender crashed or the network dropped).
  static const Duration talkTimeout = Duration(seconds: 2);

  /// The speaker is closed after being idle for this long.
  static const Duration speakerIdleClose = Duration(seconds: 3);

  String _name;
  double _micLevel = 0;
  bool _audioReady = false;
  bool _shutDown = false;

  ServerSocket? _server;
  Discovery? _discovery;
  Timer? _housekeeping;

  final Map<String, Peer> _peers = {};
  final Map<String, PeerConnection> _links = {};
  final Set<PeerConnection> _allConnections = {};
  final Map<String, Future<PeerConnection>> _connecting = {};

  TalkTarget _target = const EveryoneTarget();

  // Transmit state.
  bool _pttHeld = false;
  bool _transmitting = false;
  List<PeerConnection> _txLinks = [];
  Timer? _txPump;
  int _levelTick = 0;

  // Receive state.
  IncomingTalk? _incoming;
  bool _speakerOpen = false;
  Timer? _speakerCloser;

  final StreamController<IntercomEvent> _events =
      StreamController<IntercomEvent>.broadcast();

  // ---------------------------------------------------------------- getters

  String get name => _name;
  double get micLevel => _micLevel;
  int? get listenPort => _server?.port;
  bool get discoveryRunning => _discovery?.running ?? false;
  Stream<IntercomEvent> get events => _events.stream;
  TalkTarget get target => _target;

  /// Push-to-talk is held (we may still be connecting).
  bool get pttHeld => _pttHeld;

  /// Microphone audio is actually being sent.
  bool get transmitting => _transmitting;

  /// The transmission we're currently hearing, if any.
  IncomingTalk? get incoming => _incoming;

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

  List<Peer> get onlinePeers => _peers.values.where((p) => p.online).toList();

  /// Human readable name of [target].
  String targetName(TalkTarget t) => switch (t) {
    EveryoneTarget() => 'Everyone',
    PeerTarget(:final peerId) => _peers[peerId]?.name ?? 'Unknown',
  };

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

    _housekeeping = Timer.periodic(const Duration(seconds: 1), (_) {
      final inc = _incoming;
      if (inc != null &&
          DateTime.now().difference(inc.lastAudio) > talkTimeout) {
        _endIncoming(beep: false);
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// Stops transmitting, closes every socket and releases resources.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    stopTalking();
    _housekeeping?.cancel();
    _speakerCloser?.cancel();
    _closeSpeaker();
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

  /// Chooses who push-to-talk transmits to. Switching while transmitting
  /// ends the current transmission.
  void selectTarget(TalkTarget t) {
    if (t == _target) return;
    if (_pttHeld) stopTalking();
    _target = t;
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
      if (alt == null && _incoming?.peerId == id) _endIncoming(beep: false);
    }
    _txLinks.remove(c);
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

    switch (f.type) {
      case MessageType.hello:
        break;
      case MessageType.ping:
        c.send(Frame.empty(MessageType.pong));
      case MessageType.pong:
        break;
      case MessageType.talkStart:
        _onTalkStart(id, f.json);
      case MessageType.talkEnd:
        if (_incoming?.peerId == id) _endIncoming(beep: rogerBeep);
      case MessageType.audio:
        _onAudio(id, f.payload);
    }
  }

  // --------------------------------------------------------------- receive

  void _onTalkStart(String id, Map<String, Object?> m) {
    final current = _incoming;
    // Someone else already has the channel: ignore the newcomer.
    if (current != null && current.peerId != id) return;
    final rate = (m['sampleRate'] as int?) ?? defaultSampleRate;
    if (rate != sampleRate) {
      debugPrint('Ignoring talk at unsupported sample rate $rate');
      return;
    }
    _incoming = IncomingTalk(
      peerId: id,
      sampleRate: rate,
      group: m['group'] == true,
    );
    _openSpeaker();
    notifyListeners();
  }

  void _onAudio(String id, Uint8List payload) {
    final inc = _incoming;
    if (inc == null || inc.peerId != id) return;
    inc.lastAudio = DateTime.now();
    if (_transmitting || !_speakerOpen) return; // Half-duplex.
    final cap = audio.sampleRate * maxPlaybackLatency.inMilliseconds ~/ 1000;
    if (audio.queued > cap) audio.flushPlayback();
    audio.play(bytesToPcm(payload));
  }

  void _endIncoming({required bool beep}) {
    if (_incoming == null) return;
    _incoming = null;
    if (beep && _speakerOpen && !_transmitting) {
      audio.play(rogerTone(audio.sampleRate));
    }
    _scheduleSpeakerClose();
    notifyListeners();
  }

  void _openSpeaker() {
    _speakerCloser?.cancel();
    if (_speakerOpen) return;
    if (!_ensureAudio()) return;
    try {
      audio.startPlayback();
      _speakerOpen = true;
    } catch (e) {
      _emit('Speaker unavailable: ${_short(e)}', error: true);
    }
  }

  void _scheduleSpeakerClose() {
    _speakerCloser?.cancel();
    _speakerCloser = Timer(speakerIdleClose, () {
      if (_incoming == null) _closeSpeaker();
    });
  }

  void _closeSpeaker() {
    if (!_speakerOpen) return;
    _speakerOpen = false;
    try {
      audio.stopPlayback();
    } catch (_) {}
  }

  // -------------------------------------------------------------- transmit

  /// Push-to-talk pressed: start streaming the microphone to [target].
  Future<void> startTalking() async {
    if (_pttHeld) return;
    _pttHeld = true;
    notifyListeners();

    if (!await PlatformBridge.requestMicrophone()) {
      _pttHeld = false;
      _emit('Microphone permission denied', error: true);
      notifyListeners();
      return;
    }
    if (!_pttHeld) return; // Released while asking.

    final target = _target;
    final recipients = switch (target) {
      EveryoneTarget() => onlinePeers,
      PeerTarget(:final peerId) => [?_peers[peerId]],
    };
    if (recipients.isEmpty || recipients.every((p) => !p.online)) {
      _pttHeld = false;
      _emit(
        target is EveryoneTarget
            ? 'Nobody is online'
            : '${targetName(target)} is offline',
        error: true,
      );
      notifyListeners();
      return;
    }

    final links = <PeerConnection>[];
    await Future.wait(
      recipients.map((p) async {
        try {
          links.add(await _linkTo(p));
        } catch (e) {
          _emit('Could not reach ${p.name}: ${_short(e)}', error: true);
        }
      }),
    );
    if (!_pttHeld || target != _target) return;
    if (links.isEmpty) {
      _pttHeld = false;
      notifyListeners();
      return;
    }

    if (!_ensureAudio()) {
      _pttHeld = false;
      notifyListeners();
      return;
    }
    try {
      audio.startCapture();
    } catch (e) {
      _pttHeld = false;
      _emit('Microphone unavailable: ${_short(e)}', error: true);
      notifyListeners();
      return;
    }

    // Our own speaker would only feed back into the microphone.
    if (_speakerOpen) audio.flushPlayback();

    final start = Frame.json(MessageType.talkStart, {
      'sampleRate': sampleRate,
      'group': target is EveryoneTarget,
    });
    for (final l in links) {
      l.send(start);
    }
    _txLinks = links;
    _transmitting = true;
    _txPump?.cancel();
    _txPump = Timer.periodic(frameDuration, (_) => _pumpMic());
    notifyListeners();
  }

  /// Push-to-talk released.
  void stopTalking() {
    if (!_pttHeld && !_transmitting) return;
    _pttHeld = false;
    if (_transmitting) {
      _pumpMic(); // Send the tail end of what was said.
      _txPump?.cancel();
      _txPump = null;
      final end = Frame.empty(MessageType.talkEnd);
      for (final l in _txLinks) {
        l.send(end);
      }
      _txLinks = [];
      _transmitting = false;
      try {
        audio.stopCapture();
      } catch (_) {}
    }
    _micLevel = 0;
    notifyListeners();
  }

  void _pumpMic() {
    if (!_transmitting) return;
    final samples = audio.readCaptured();
    if (samples.isEmpty) return;
    final frame = Frame(MessageType.audio, pcmToBytes(samples));
    for (final l in _txLinks) {
      l.send(frame);
    }
    _micLevel = rmsLevel(samples);
    // Refresh the level meter ~10x per second.
    if (++_levelTick % 5 == 0) notifyListeners();
  }

  bool _ensureAudio() {
    if (_audioReady) return true;
    try {
      audio.init(sampleRate);
      _audioReady = true;
    } catch (e) {
      _emit('Audio unavailable: ${_short(e)}', error: true);
    }
    return _audioReady;
  }

  // ---------------------------------------------------------------- helpers

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

  /// Short two-tone "over" chirp played when a transmission ends.
  static Int16List rogerTone(int rate) {
    final out = <int>[];
    for (final (freq, ms) in [(1400.0, 60), (1000.0, 80)]) {
      final n = rate * ms ~/ 1000;
      for (var i = 0; i < n; i++) {
        final fade = math.min(1.0, math.min(i, n - i) / (rate * 0.005));
        out.add(
          (5000 * fade * math.sin(2 * math.pi * freq * i / rate)).round(),
        );
      }
    }
    return Int16List.fromList(out);
  }

  void _emit(String message, {bool error = false}) {
    if (!_events.isClosed) _events.add(IntercomEvent(message, error: error));
  }

  static String _short(Object e) {
    if (e is SocketException) return e.osError?.message ?? e.message;
    if (e is TimeoutException) return e.message ?? 'timed out';
    return e.toString();
  }
}
