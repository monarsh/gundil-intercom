import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_engine.dart';
import 'discovery.dart';
import 'models.dart';
import 'peer_connection.dart';
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
/// Platform-specific hooks. The defaults do nothing, which is right for
/// desktop and headless use; the Flutter app supplies Android versions.
class PlatformHooks {
  const PlatformHooks();

  /// Asks for microphone permission. Returns true when allowed.
  Future<bool> requestMicrophone() async => true;

  /// Keeps broadcast/multicast reception alive (Android Wi-Fi).
  Future<void> acquireMulticastLock() async {}
  Future<void> releaseMulticastLock() async {}
}

/// Pure-Dart intercom engine shared by the Flutter app and the headless
/// node (bin/gundil_node.dart). The Flutter app wraps it in
/// `IntercomService` (a ChangeNotifier) for the UI.
class IntercomCore {
  /// Diagnostic logger (the Flutter app routes this to debugPrint).
  static void Function(String message) log = print;

  IntercomCore({
    required this.selfId,
    required String name,
    required this.audio,
    this.preferredPort = defaultTcpPort,
    this.enableDiscovery = true,
    this.discoveryUdpPort = discoveryPort,
    this.sampleRate = defaultSampleRate,
    this.rogerBeep = true,
    List<SavedPeer> savedPeers = const [],
    this.onSavedPeersChanged,
    this.reconnectInterval = const Duration(seconds: 5),
    this.hooks = const PlatformHooks(),
  }) : _name = name, // ignore: prefer_initializing_formals
       _saved = [...savedPeers];

  final String selfId;
  final AudioEngine audio;
  final int preferredPort;
  final bool enableDiscovery;
  final int discoveryUdpPort;
  final int sampleRate;

  /// Play a short "over" chirp when a remote transmission ends.
  final bool rogerBeep;

  /// Called whenever the saved peer list changes, so it can be persisted.
  final void Function(List<SavedPeer> saved)? onSavedPeersChanged;

  /// How often offline saved peers are retried.
  final Duration reconnectInterval;

  final PlatformHooks hooks;

  final List<void Function()> _listeners = [];

  /// Registers [listener] to be called on every state change. (The Flutter
  /// subclass uses ChangeNotifier instead; this is for headless use.)
  void onChange(void Function() listener) => _listeners.add(listener);

  /// Called whenever observable state changes.
  void changed() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Called at the end of [shutdown].
  void onShutdown() {}

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
  Timer? _reconnect;

  final List<SavedPeer> _saved;
  final Set<String> _savedConnecting = {};

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

  /// Saved peers, in the order they were added.
  List<SavedPeer> get savedPeers => List.unmodifiable(_saved);

  /// Everything to show in the peer list: saved peers (online or not) plus
  /// discovered peers that aren't saved. Online first, then by name.
  List<PeerEntry> get entries {
    final out = <PeerEntry>[];
    final shown = <String>{};
    for (final s in _saved) {
      final live = s.peerId == null ? null : _peers[s.peerId];
      if (live != null) shown.add(live.id);
      out.add(PeerEntry(saved: s, live: live));
    }
    for (final p in _peers.values) {
      if (!shown.contains(p.id)) out.add(PeerEntry(live: p));
    }
    out.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  List<Peer> get onlinePeers => _peers.values.where((p) => p.online).toList();

  /// Name to show for a peer: the user's label if saved, else its own name.
  String displayName(String peerId) {
    for (final s in _saved) {
      if (s.peerId == peerId && s.label.trim().isNotEmpty) return s.label;
    }
    return _peers[peerId]?.name ?? 'Unknown';
  }

  /// Human readable name of [target].
  String targetName(TalkTarget t) => switch (t) {
    EveryoneTarget() => 'Everyone',
    PeerTarget(:final peerId) => displayName(peerId),
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
      await hooks.acquireMulticastLock();
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
      changed();
    });
    _reconnect = Timer.periodic(reconnectInterval, (_) => _retrySaved());
    _retrySaved();
    changed();
  }

  /// Stops transmitting, closes every socket and releases resources.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    stopTalking();
    _housekeeping?.cancel();
    _reconnect?.cancel();
    _speakerCloser?.cancel();
    _closeSpeaker();
    await _discovery?.dispose();
    await hooks.releaseMulticastLock();
    for (final c in _allConnections.toList()) {
      await c.close();
    }
    await _server?.close();
    await _events.close();
    onShutdown();
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
    changed();
  }

  /// Chooses who push-to-talk transmits to. Switching while transmitting
  /// ends the current transmission.
  void selectTarget(TalkTarget t) {
    if (t == _target) return;
    if (_pttHeld) stopTalking();
    _target = t;
    changed();
  }

  // ---------------------------------------------------------------- peers

  /// Saves a peer by IP address/hostname. It stays in the list (offline
  /// when unreachable) until removed, and is retried in the background.
  /// Returns true if it could be reached right now.
  Future<bool> addSavedPeer({
    required String host,
    int port = defaultTcpPort,
    String label = '',
  }) async {
    final h = host.trim();
    if (h.isEmpty) throw ArgumentError('Host is empty');
    if (_saved.any((s) => s.host == h && s.port == port)) {
      throw ArgumentError('$h:$port is already in the list');
    }
    final s = SavedPeer(
      key: _newKey(),
      host: h,
      port: port,
      label: label.trim(),
    );
    _saved.add(s);
    _savedChanged();
    return _tryConnectSaved(s);
  }

  /// Saves a discovered peer (e.g. to give it a custom name).
  SavedPeer saveLivePeer(String peerId, {String label = ''}) {
    final existing = _saved.where((s) => s.peerId == peerId).firstOrNull;
    if (existing != null) return existing;
    final p = _peers[peerId];
    if (p == null) throw ArgumentError('Unknown peer $peerId');
    final s = SavedPeer(
      key: _newKey(),
      host: p.address.address,
      port: p.port,
      label: label.trim(),
      peerId: peerId,
    );
    _saved.add(s);
    _savedChanged();
    return s;
  }

  /// Edits a saved peer. Changing the address reconnects to it.
  Future<bool> updateSavedPeer(
    String key, {
    String? label,
    String? host,
    int? port,
  }) async {
    final s = _saved.where((e) => e.key == key).firstOrNull;
    if (s == null) return false;
    if (label != null) s.label = label.trim();
    final newHost = host?.trim();
    final addressChanged =
        (newHost != null && newHost.isNotEmpty && newHost != s.host) ||
        (port != null && port != s.port);
    if (addressChanged) {
      if (_saved.any(
        (o) =>
            o != s &&
            o.host == (newHost ?? s.host) &&
            o.port == (port ?? s.port),
      )) {
        throw ArgumentError(
          '${newHost ?? s.host}:${port ?? s.port} is already in the list',
        );
      }
      if (newHost != null && newHost.isNotEmpty) s.host = newHost;
      if (port != null) s.port = port;
      // May now point at a different device; learn its id again.
      s.peerId = null;
    }
    _savedChanged();
    if (addressChanged) return _tryConnectSaved(s);
    return _peers[s.peerId]?.online ?? false;
  }

  /// Removes a saved peer from the list (a discovered peer reappears as
  /// unsaved while it's online).
  void removeSavedPeer(String key) {
    _saved.removeWhere((s) => s.key == key);
    _savedChanged();
  }

  void _savedChanged() {
    onSavedPeersChanged?.call(savedPeers);
    changed();
  }

  static final math.Random _rng = math.Random();
  static String _newKey() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 30).toRadixString(36)}';

  void _retrySaved() {
    for (final s in _saved) {
      final live = s.peerId == null ? null : _peers[s.peerId];
      if (live != null && live.online) continue;
      _tryConnectSaved(s);
    }
  }

  /// Connects to a saved peer and learns its id. Never throws.
  Future<bool> _tryConnectSaved(SavedPeer s) async {
    if (_shutDown || !_savedConnecting.add(s.key)) return false;
    PeerConnection? conn;
    try {
      final addrs = await InternetAddress.lookup(
        s.host,
      ).timeout(const Duration(seconds: 3));
      if (addrs.isEmpty) return false;
      conn = await PeerConnection.connect(
        addrs.first,
        s.port,
        timeout: const Duration(seconds: 3),
      );
      if (_shutDown) {
        conn.close();
        return false;
      }
      final hello = Completer<String>();
      _adopt(
        conn,
        onHello: (id) {
          if (!hello.isCompleted) hello.complete(id);
        },
      );
      final id = await hello.future.timeout(const Duration(seconds: 4));
      if (!_saved.contains(s)) return true; // Removed meanwhile.
      if (s.peerId != id) {
        s.peerId = id;
        _savedChanged();
      }
      final live = _peers[id];
      if (live != null) _resolveSaved(live);
      changed();
      return true;
    } catch (_) {
      conn?.close();
      return false;
    } finally {
      _savedConnecting.remove(s.key);
    }
  }

  /// Keeps saved peers in sync with a live peer [p]:
  /// * links saved entries that don't know their device id yet when the
  ///   address matches (e.g. discovered before we connected to it);
  /// * for entries linked to [p], refreshes the platform and — when the saved
  ///   host is an IP address — the address, so reconnecting keeps working
  ///   after the device gets a new IP or port.
  void _resolveSaved(Peer p) {
    var updated = false;
    for (final s in _saved) {
      if (s.peerId == null &&
          s.host == p.address.address &&
          s.port == p.port &&
          !_saved.any((o) => o.peerId == p.id)) {
        s.peerId = p.id;
        updated = true;
      }
      if (s.peerId != p.id) continue;
      if (s.platform != p.platform && p.platform != '?') {
        s.platform = p.platform;
        updated = true;
      }
      final isIp = InternetAddress.tryParse(s.host) != null;
      if (isIp &&
          p.online &&
          (s.host != p.address.address || s.port != p.port) &&
          !_saved.any(
            (o) => o != s && o.host == p.address.address && o.port == p.port,
          )) {
        s.host = p.address.address;
        s.port = p.port;
        updated = true;
      }
    }
    if (updated) _savedChanged();
  }

  void _onBeacon(DiscoveryBeacon b) {
    if (b.leaving) {
      final p = _peers[b.id];
      if (p != null) {
        p.lastBeacon = null;
        changed();
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
      final differs =
          existing.name != name ||
          existing.address != address ||
          existing.port != port;
      existing
        ..name = name
        ..platform = platform
        ..address = address
        ..port = port;
      if (differs) changed();
      _resolveSaved(existing);
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
    _resolveSaved(p);
    changed();
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
    changed();
  }

  void _onFrame(PeerConnection c, Frame f, void Function(String id)? onHello) {
    try {
      _handleFrame(c, f, onHello);
    } catch (e) {
      log('Bad ${f.type.name} frame: $e');
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
      _resolveSaved(p);
      onHello?.call(id);
      changed();
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
      log('Ignoring talk at unsupported sample rate $rate');
      return;
    }
    _incoming = IncomingTalk(
      peerId: id,
      sampleRate: rate,
      group: m['group'] == true,
    );
    _openSpeaker();
    changed();
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
    changed();
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
    changed();

    if (!await hooks.requestMicrophone()) {
      _pttHeld = false;
      _emit('Microphone permission denied', error: true);
      changed();
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
      changed();
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
      changed();
      return;
    }

    if (!_ensureAudio()) {
      _pttHeld = false;
      changed();
      return;
    }
    try {
      audio.startCapture();
    } catch (e) {
      _pttHeld = false;
      _emit('Microphone unavailable: ${_short(e)}', error: true);
      changed();
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
    changed();
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
    changed();
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
    if (++_levelTick % 5 == 0) changed();
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
