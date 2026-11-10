import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_engine.dart';
import 'discovery.dart';
import 'echo_suppressor.dart';
import 'mixer.dart';
import 'models.dart';
import 'peer_connection.dart';
import 'protocol.dart';

/// Notification for the UI (errors and short info messages).
class IntercomEvent {
  IntercomEvent(
    this.message, {
    this.error = false,
    this.kind = IntercomEventKind.info,
    this.peerId,
  });
  final String message;
  final bool error;
  final IntercomEventKind kind;

  /// The peer the event is about, if any.
  final String? peerId;
}

enum IntercomEventKind {
  info,

  /// A two-way line with [IntercomEvent.peerId] just opened.
  connected,

  /// The line with [IntercomEvent.peerId] closed (hang-up, lost, ...).
  disconnected,

  /// [IntercomEvent.peerId] is ringing us (auto-answer off).
  ringing,
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

  /// Switches the device to two-way call audio (Android: voice
  /// communication mode with echo cancellation, loudspeaker or earpiece).
  Future<void> startCallAudio({required bool speaker}) async {}
  Future<void> setSpeaker(bool speaker) async {}
  Future<void> stopCallAudio() async {}
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
    this.autoAnswer = true,
    bool? echoSuppression,
    List<SavedPeer> savedPeers = const [],
    this.onSavedPeersChanged,
    this.reconnectInterval = const Duration(seconds: 5),
    this.hooks = const PlatformHooks(),
  }) : _name = name, // ignore: prefer_initializing_formals
       _saved = [...savedPeers],
       // Android uses the phone's hardware echo canceller instead.
       echoSuppression = echoSuppression ?? !Platform.isAndroid,
       _mixer = AudioMixer(sampleRate: sampleRate),
       _echo = EchoSuppressor(sampleRate: sampleRate);

  final String selfId;
  final AudioEngine audio;
  final int preferredPort;
  final bool enableDiscovery;
  final int discoveryUdpPort;
  final int sampleRate;

  /// Play connect / hang-up / ring tones.
  final bool rogerBeep;

  /// Accept incoming connections immediately (intercom behaviour). When
  /// false, they ring until [accept] or [decline].
  bool autoAnswer;

  /// Turn the microphone down while the far end talks (for devices without
  /// a hardware echo canceller).
  bool echoSuppression;

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

  /// Unanswered invitations are cancelled after this long.
  static const Duration ringTimeout = Duration(seconds: 30);

  /// A connected member we hear nothing from (not even pings) for this long
  /// is dropped (crashed, out of Wi-Fi range, ...).
  static const Duration memberTimeout = Duration(seconds: 8);

  /// Incoming level (see [rmsLevel], 0..1 ≈ -60..0 dBFS) counted as voice.
  static const double speakingThreshold = 0.38;

  /// A speaker stays "speaking" this long after their last loud chunk, so
  /// the indicator doesn't flicker between words.
  static const Duration speakingHold = Duration(milliseconds: 400);

  /// Audio kept queued in the speaker (absorbs timer jitter).
  int get playbackTarget => sampleRate * 100 ~/ 1000;

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

  // Conversation state.
  Conversation? _conversation;
  bool _muted = false;
  bool _speaker = true;
  bool _audioRunning = false;
  bool _micOk = false;
  double _speakerLevel = 0;
  Timer? _pump;
  Timer? _ringTimer;

  // Who is speaking: last level and last time voice was heard, per peer.
  final Map<String, double> _peerLevel = {};
  final Map<String, DateTime> _levelAt = {};
  final Map<String, DateTime> _voiceAt = {};
  final AudioMixer _mixer;
  final EchoSuppressor _echo;

  final StreamController<IntercomEvent> _events =
      StreamController<IntercomEvent>.broadcast();

  // ---------------------------------------------------------------- getters

  String get name => _name;
  double get micLevel => _micLevel;
  int? get listenPort => _server?.port;
  bool get discoveryRunning => _discovery?.running ?? false;
  Stream<IntercomEvent> get events => _events.stream;
  TalkTarget get target => _target;

  /// The current two-way line (calling, ringing or connected), if any.
  Conversation? get conversation => _conversation;

  /// Two-way audio is flowing with at least one peer.
  bool get inConversation => _conversation?.isConnected ?? false;

  /// Someone is ringing us (auto-answer off).
  bool get ringing => _conversation?.ringing.isNotEmpty ?? false;

  /// State of [peerId] in the conversation, if it's a member.
  MemberState? memberState(String peerId) => _conversation?.members[peerId];

  bool get muted => _muted;
  bool get speaker => _speaker;

  /// Level of the audio we're playing (0..1), for a meter.
  double get speakerLevel => _speakerLevel;

  /// Current incoming level of [peerId] (0..1), 0 when silent.
  double peerLevel(String peerId) {
    final at = _levelAt[peerId];
    if (at == null ||
        DateTime.now().difference(at) > const Duration(milliseconds: 300)) {
      return 0;
    }
    return _peerLevel[peerId] ?? 0;
  }

  /// Whether [peerId] is talking to us right now.
  bool isSpeaking(String peerId) {
    final at = _voiceAt[peerId];
    return at != null && DateTime.now().difference(at) < speakingHold;
  }

  /// Connected peers that are talking right now.
  List<String> get speakers => [
    for (final id in _conversation?.connected ?? const <String>[])
      if (isSpeaking(id)) id,
  ];

  /// Whether we are talking (microphone above the voice threshold).
  bool get selfSpeaking =>
      _audioRunning && !_muted && _micLevel >= speakingThreshold;

  /// Current echo-suppression microphone gain (1 = open).
  double get micGain => echoSuppression ? _echo.gain : 1;

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
      _checkConversation();
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
    hangUp();
    _stopRinging();
    _stopAudio();
    _housekeeping?.cancel();
    _reconnect?.cancel();
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

  /// Chooses who [connect] talks to. Doesn't affect an ongoing
  /// conversation; connecting to the new target hangs that up.
  void selectTarget(TalkTarget t) {
    if (t == _target) return;
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
    p.version = b.version;
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
      if (alt == null && (_conversation?.members.containsKey(id) ?? false)) {
        _removeMember(id, reason: 'Lost connection to ${displayName(id)}');
      }
    }
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
      p.version = (m['v'] as int?) ?? 1;
      _resolveSaved(p);
      onHello?.call(id);
      changed();
      return;
    }

    final id = c.remoteId;
    if (id == null) return; // Must say hello first.
    _heard(id);

    switch (f.type) {
      case MessageType.hello:
        break;
      case MessageType.ping:
        c.send(Frame.empty(MessageType.pong));
      case MessageType.pong:
        break;
      case MessageType.open:
        _onOpen(id, f.json);
      case MessageType.accept:
        _onAccept(id);
      case MessageType.reject:
        _onReject(id, f.json['reason'] as String?);
      case MessageType.close:
        _onClose(id);
      case MessageType.audio:
        _onAudio(id, f.payload);
    }
  }

  // ----------------------------------------------------------- conversation

  /// Opens a two-way audio line with [t] (default: the selected target).
  /// An existing conversation is hung up first, which is how the user
  /// switches between peers.
  Future<void> connect([TalkTarget? t]) async {
    final target = t ?? _target;
    if (t != null) _target = t;
    if (_conversation != null) hangUp();

    final recipients = switch (target) {
      EveryoneTarget() => onlinePeers,
      PeerTarget(:final peerId) => [?_peers[peerId]],
    }.where((p) => p.online).toList();
    if (recipients.isEmpty) {
      _emit(
        target is EveryoneTarget
            ? 'Nobody is online'
            : '${targetName(target)} is offline',
        error: true,
      );
      return;
    }
    final outdated = recipients.where((p) => p.outdated).toList();
    for (final p in outdated) {
      _emit(
        '${displayName(p.id)} runs an older Gundil Intercom without two-way '
        'audio. Please update it.',
        error: true,
      );
    }
    recipients.removeWhere((p) => p.outdated);
    if (recipients.isEmpty) return;

    if (!await hooks.requestMicrophone()) {
      _emit('Microphone permission denied', error: true);
      return;
    }

    // Something started while we waited (e.g. they called us first).
    final existing = _conversation;
    if (existing != null) {
      final ids = recipients.map((p) => p.id).toSet();
      if (existing.members.keys.any(ids.contains)) return; // Already on.
      hangUp();
    }

    final conv = Conversation(group: target is EveryoneTarget, outgoing: true);
    _conversation = conv;
    final now = DateTime.now();
    for (final p in recipients) {
      conv.members[p.id] = MemberState.calling;
      conv.invitedAt[p.id] = now;
    }
    changed();

    final open = Frame.json(MessageType.open, {
      'sampleRate': sampleRate,
      'group': conv.group,
    });
    await Future.wait(
      recipients.map((p) async {
        try {
          final link = await _linkTo(p);
          if (!identical(_conversation, conv)) return;
          link.send(open);
        } catch (e) {
          if (!identical(_conversation, conv)) return;
          _emit(
            'Could not reach ${displayName(p.id)}: ${_short(e)}',
            error: true,
          );
          _removeMember(p.id);
        }
      }),
    );
  }

  /// Accepts every peer that is ringing us.
  Future<void> accept() async {
    final conv = _conversation;
    if (conv == null) return;
    final ringing = conv.ringing.toList();
    if (ringing.isEmpty) return;
    if (!await hooks.requestMicrophone()) {
      _emit(
        'Microphone permission denied — you can listen but not talk',
        error: true,
      );
    }
    if (!identical(_conversation, conv)) return;
    for (final id in ringing) {
      _send(id, Frame.empty(MessageType.accept));
      _setConnected(id);
    }
  }

  /// Declines every peer that is ringing us.
  void decline() {
    final conv = _conversation;
    if (conv == null) return;
    for (final id in conv.ringing.toList()) {
      _send(id, Frame.json(MessageType.reject, {'reason': 'declined'}));
      _removeMember(id, quiet: true);
    }
  }

  /// Leaves the conversation (tells every member).
  void hangUp() {
    final conv = _conversation;
    if (conv == null) return;
    for (final entry in conv.members.entries) {
      _send(
        entry.key,
        entry.value == MemberState.ringing
            ? Frame.json(MessageType.reject, {'reason': 'declined'})
            : Frame.empty(MessageType.close),
      );
    }
    _endConversation(null);
  }

  void toggleMute() {
    _muted = !_muted;
    if (_muted) _micLevel = 0;
    changed();
  }

  void toggleSpeaker() {
    _speaker = !_speaker;
    hooks.setSpeaker(_speaker);
    changed();
  }

  void _onOpen(String id, Map<String, Object?> m) {
    final rate = (m['sampleRate'] as int?) ?? defaultSampleRate;
    if (rate != sampleRate) {
      _send(id, Frame.json(MessageType.reject, {'reason': 'unsupported'}));
      return;
    }
    final conv = _conversation;
    if (conv != null) {
      final state = conv.members[id];
      if (state == MemberState.calling) {
        // We called each other at the same moment: just connect.
        _send(id, Frame.empty(MessageType.accept));
        _setConnected(id);
        return;
      }
      if (state != null) return; // Already ringing / connected.
      _send(id, Frame.json(MessageType.reject, {'reason': 'busy'}));
      return;
    }
    final next = Conversation(group: m['group'] == true, outgoing: false);
    next.members[id] = MemberState.ringing;
    next.invitedAt[id] = DateTime.now();
    _conversation = next;
    if (autoAnswer) {
      accept();
    } else {
      _emit(
        '${displayName(id)} wants to talk',
        kind: IntercomEventKind.ringing,
        peerId: id,
      );
      _startRinging();
    }
    changed();
  }

  void _onAccept(String id) {
    final conv = _conversation;
    final state = conv?.members[id];
    if (state == MemberState.connected) return; // We crossed: already on.
    if (conv == null || state != MemberState.calling) {
      // Late accept for a line we already left: tell them.
      _send(id, Frame.empty(MessageType.close));
      return;
    }
    _setConnected(id);
  }

  void _onReject(String id, String? reason) {
    final conv = _conversation;
    if (conv == null || !conv.members.containsKey(id)) return;
    final who = displayName(id);
    final quiet = conv.group; // Don't spam when paging everyone.
    if (!quiet) {
      _emit(switch (reason) {
        'busy' => '$who is busy',
        'timeout' => '$who did not answer',
        'unsupported' => '$who uses an incompatible audio format',
        _ => '$who declined',
      });
    }
    _removeMember(id, quiet: true);
  }

  void _onClose(String id) {
    final conv = _conversation;
    if (conv == null || !conv.members.containsKey(id)) return;
    final wasRinging = conv.members[id] == MemberState.ringing;
    _removeMember(
      id,
      reason: wasRinging
          ? 'Missed call from ${displayName(id)}'
          : '${displayName(id)} hung up',
    );
  }

  void _setConnected(String id) {
    final conv = _conversation;
    if (conv == null) return;
    final first = !conv.isConnected;
    conv.members[id] = MemberState.connected;
    conv.lastHeard[id] = DateTime.now();
    if (conv.ringing.isEmpty) _stopRinging();
    if (first) {
      conv.connectedAt = DateTime.now();
      _startAudio();
      if (rogerBeep && _audioRunning) audio.play(connectTone(sampleRate));
    }
    _emit(
      '${displayName(id)} connected',
      kind: IntercomEventKind.connected,
      peerId: id,
    );
    changed();
  }

  /// Removes [id] from the conversation; ends it when nobody is left.
  void _removeMember(String id, {String? reason, bool quiet = false}) {
    final conv = _conversation;
    if (conv == null) return;
    final wasConnected = conv.members[id] == MemberState.connected;
    conv.members.remove(id);
    conv.lastHeard.remove(id);
    conv.invitedAt.remove(id);
    _mixer.remove(id);
    _clearLevels(id);
    final kind = wasConnected
        ? IntercomEventKind.disconnected
        : IntercomEventKind.info;
    if (conv.members.isEmpty) {
      _endConversation(quiet ? null : reason, kind: kind, peerId: id);
    } else {
      if (conv.ringing.isEmpty) _stopRinging();
      if (reason != null && !quiet && conv.group) {
        _emit(reason, kind: kind, peerId: id);
      }
      changed();
    }
  }

  void _clearLevels(String id) {
    _peerLevel.remove(id);
    _levelAt.remove(id);
    _voiceAt.remove(id);
  }

  void _endConversation(
    String? reason, {
    IntercomEventKind kind = IntercomEventKind.info,
    String? peerId,
  }) {
    _stopRinging();
    if (_audioRunning && rogerBeep) {
      audio.play(hangupTone(sampleRate));
      // Let the tone play out before closing the devices, unless a new
      // conversation has connected meanwhile (switching peers).
      Timer(const Duration(milliseconds: 300), () {
        if (!(_conversation?.isConnected ?? false)) _stopAudio();
      });
    } else {
      _stopAudio();
    }
    _conversation = null;
    _mixer.clear();
    _peerLevel.clear();
    _levelAt.clear();
    _voiceAt.clear();
    if (reason != null) _emit(reason, kind: kind, peerId: peerId);
    changed();
  }

  /// Called every second: invitation timeouts and dead members.
  void _checkConversation() {
    final conv = _conversation;
    if (conv == null) return;
    final now = DateTime.now();
    for (final entry in conv.members.entries.toList()) {
      final id = entry.key;
      switch (entry.value) {
        case MemberState.calling:
          if (now.difference(conv.invitedAt[id] ?? now) > ringTimeout) {
            _send(id, Frame.empty(MessageType.close));
            _removeMember(id, reason: '${displayName(id)} did not answer');
          }
        case MemberState.ringing:
          if (now.difference(conv.invitedAt[id] ?? now) > ringTimeout) {
            _send(id, Frame.json(MessageType.reject, {'reason': 'timeout'}));
            _removeMember(id, reason: 'Missed call from ${displayName(id)}');
          }
        case MemberState.connected:
          _send(id, Frame.empty(MessageType.ping));
          if (now.difference(conv.lastHeard[id] ?? now) > memberTimeout) {
            _removeMember(id, reason: 'Lost connection to ${displayName(id)}');
          }
      }
    }
  }

  void _heard(String id) {
    final conv = _conversation;
    if (conv != null && conv.members[id] == MemberState.connected) {
      conv.lastHeard[id] = DateTime.now();
    }
  }

  void _send(String id, Frame f) {
    final link = _links[id];
    if (link != null && !link.isClosed) link.send(f);
  }

  // ------------------------------------------------------------------ audio

  void _onAudio(String id, Uint8List payload) {
    final conv = _conversation;
    if (conv == null || conv.members[id] != MemberState.connected) return;
    final now = DateTime.now();
    conv.lastHeard[id] = now;
    final samples = bytesToPcm(payload);
    final level = rmsLevel(samples);
    _peerLevel[id] = level;
    _levelAt[id] = now;
    if (level >= speakingThreshold) _voiceAt[id] = now;
    if (_audioRunning) _mixer.add(id, samples);
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

  void _startAudio() {
    if (_audioRunning) return;
    if (!_ensureAudio()) return;
    hooks.startCallAudio(speaker: _speaker);
    try {
      audio.startPlayback();
    } catch (e) {
      _emit('Speaker unavailable: ${_short(e)}', error: true);
    }
    try {
      audio.startCapture();
      _micOk = true;
    } catch (e) {
      _micOk = false;
      _emit(
        'Microphone unavailable: ${_short(e)} — you can listen only',
        error: true,
      );
    }
    _echo.reset();
    _mixer.clear();
    _audioRunning = true;
    _pump?.cancel();
    _pump = Timer.periodic(frameDuration, (_) => _pumpAudio());
  }

  void _stopAudio() {
    _pump?.cancel();
    _pump = null;
    if (!_audioRunning) return;
    _audioRunning = false;
    _micLevel = 0;
    _speakerLevel = 0;
    try {
      audio.stopCapture();
    } catch (_) {}
    try {
      audio.stopPlayback();
    } catch (_) {}
    hooks.stopCallAudio();
  }

  int _levelTick = 0;

  /// Every 20 ms: mix incoming audio to the speaker, send the microphone.
  void _pumpAudio() {
    final conv = _conversation;
    if (conv == null || !_audioRunning) return;

    // Speaker: keep ~100 ms queued in the device.
    final want = playbackTarget - audio.queued;
    if (want > 0) {
      final mixed = _mixer.take(want);
      if (mixed != null) {
        audio.play(mixed);
        if (echoSuppression) _echo.onPlayback(mixed);
        _speakerLevel = rmsLevel(mixed);
      } else {
        _speakerLevel = 0;
      }
    }

    // Microphone → every connected member.
    if (_micOk) {
      final mic = audio.readCaptured();
      if (mic.isNotEmpty) {
        if (_muted) {
          _micLevel = 0;
        } else {
          if (echoSuppression) _echo.process(mic);
          _micLevel = rmsLevel(mic);
          final frame = Frame(MessageType.audio, pcmToBytes(mic));
          for (final id in conv.connected) {
            _send(id, frame);
          }
        }
      }
    }
    if (++_levelTick % 5 == 0) changed();
  }

  void _startRinging() {
    _ringTimer?.cancel();
    if (!rogerBeep || !_ensureAudio()) return;
    try {
      audio.startPlayback();
    } catch (_) {
      return;
    }
    void ring() => audio.play(ringTone(sampleRate));
    ring();
    _ringTimer = Timer.periodic(const Duration(seconds: 2), (_) => ring());
  }

  void _stopRinging() {
    final wasRinging = _ringTimer != null;
    _ringTimer?.cancel();
    _ringTimer = null;
    if (wasRinging && !_audioRunning) {
      try {
        audio.stopPlayback();
      } catch (_) {}
    }
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

  /// Rising two-tone chime: the line is open.
  static Int16List connectTone(int rate) =>
      _tones(rate, [(800.0, 70), (1200.0, 90)]);

  /// Falling two-tone chime: the line was closed.
  static Int16List hangupTone(int rate) =>
      _tones(rate, [(1200.0, 70), (700.0, 110)]);

  /// Short ring burst played every 2 s while someone is ringing us.
  static Int16List ringTone(int rate) =>
      _tones(rate, [(1000.0, 120), (0.0, 60), (1000.0, 120)]);

  static Int16List _tones(int rate, List<(double, int)> parts) {
    final out = <int>[];
    for (final (freq, ms) in parts) {
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

  void _emit(
    String message, {
    bool error = false,
    IntercomEventKind kind = IntercomEventKind.info,
    String? peerId,
  }) {
    if (_events.isClosed) return;
    _events.add(
      IntercomEvent(message, error: error, kind: kind, peerId: peerId),
    );
  }

  static String _short(Object e) {
    if (e is SocketException) return e.osError?.message ?? e.message;
    if (e is TimeoutException) return e.message ?? 'timed out';
    return e.toString();
  }
}
