import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_engine.dart';
import 'discovery.dart';
import 'echo_suppressor.dart';
import 'mixer.dart';
import 'models.dart';
import 'peer_connection.dart';
import 'protocol.dart';
import 'secure_channel.dart';

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
  /// communication mode with echo cancellation; the output — speaker,
  /// earpiece, Bluetooth, wired headset — is chosen by the platform and the
  /// app's audio-output picker).
  Future<void> startCallAudio() async {}
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
    this.videoReceive = false,
    String password = '',
    double speakerVolume = 1,
    double micVolume = 1,
    bool? echoSuppression,
    List<SavedPeer> savedPeers = const [],
    this.onSavedPeersChanged,
    List<Group> groups = const [],
    this.onGroupsChanged,
    this.reconnectInterval = const Duration(seconds: 5),
    this.hooks = const PlatformHooks(),
  }) : _name = name, // ignore: prefer_initializing_formals
       _password = password,
       _speakerVolume = speakerVolume.clamp(0.0, maxVolume),
       _micVolume = micVolume.clamp(0.0, maxVolume),
       _saved = [...savedPeers],
       _groups = {for (final g in groups) g.id: g},
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

  /// This device can show camera video from peers (the app, not the
  /// headless node). Announced in HELLO; peers only send video if it's set.
  final bool videoReceive;

  /// Called whenever the saved peer list changes, so it can be persisted.
  final void Function(List<SavedPeer> saved)? onSavedPeersChanged;

  /// Called whenever the groups change, so they can be persisted.
  final void Function(List<Group> groups)? onGroupsChanged;

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
  /// is dropped (crashed, out of Wi-Fi range, ...). Until then the call
  /// stays up and the link is redialled (see [relinkAfter]), so switching
  /// networks (Wi-Fi ⇄ mobile data, VPN on/off) doesn't end the call.
  static const Duration memberTimeout = Duration(seconds: 15);

  /// In a call, a member silent for this long (pings go every second) is
  /// dialled again on a new connection; shown as "Reconnecting…".
  static const Duration relinkAfter = Duration(seconds: 3);

  /// Idle links are pinged when nothing arrived for this long...
  static const Duration linkPingInterval = Duration(seconds: 5);

  /// ...and closed when nothing arrived for this long. A link whose network
  /// went away doesn't fail by itself (TCP gives up after many minutes); it
  /// just goes silent, and the peer would look online forever.
  static const Duration linkTimeout = Duration(seconds: 15);

  /// After a network change every link must answer within this long.
  static const Duration probeTimeout = Duration(seconds: 4);

  /// How often the network interfaces are checked for changes.
  static const Duration networkCheckInterval = Duration(seconds: 2);

  /// Incoming level (see [rmsLevel], 0..1 ≈ -60..0 dBFS) counted as voice.
  static const double speakingThreshold = 0.38;

  /// A speaker stays "speaking" this long after their last loud chunk, so
  /// the indicator doesn't flicker between words.
  static const Duration speakingHold = Duration(milliseconds: 400);

  /// Camera pictures sent to one peer and not acknowledged yet. New pictures
  /// are skipped while this many are on the way (slow network).
  static const int maxVideoInFlight = 2;

  /// A peer's video disappears when no picture arrived for this long (its
  /// camera stopped, e.g. the app went to the background).
  static const Duration videoStale = Duration(seconds: 3);

  /// Audio kept queued in the speaker (absorbs timer jitter).
  int get playbackTarget => sampleRate * 100 ~/ 1000;

  String _name;
  String _password;
  double _speakerVolume;
  double _micVolume;
  Uint8List _secret = networkSecret('');
  double _micLevel = 0;
  bool _audioReady = false;
  bool _shutDown = false;

  ServerSocket? _server;
  Discovery? _discovery;
  Timer? _housekeeping;
  Timer? _reconnect;
  Timer? _netWatch;
  String? _netFingerprint;
  Set<String> _localAddresses = {};
  bool _netChecking = false;
  final Set<String> _relinking = {};

  final List<SavedPeer> _saved;
  final Map<String, Group> _groups;

  /// Tests only: device ids we pretend we can't connect to (no route).
  final Set<String> debugUnreachable = {};

  /// How to reach group call members we may not know yet (from rosters).
  final Map<String, ({String name, int port, List<InternetAddress> addrs})>
  _dialInfo = {};

  final Set<String> _savedConnecting = {};

  final Map<String, Peer> _peers = {};
  final Map<String, PeerConnection> _links = {};
  final Set<PeerConnection> _allConnections = {};
  final Map<String, Future<PeerConnection>> _connecting = {};

  TalkTarget _target = const EveryoneTarget();

  // Conversation state.
  Conversation? _conversation;
  bool _muted = false;
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

  // Camera video.
  bool _cameraOn = false;
  final Map<String, VideoFrame> _remoteVideo = {};
  final Map<String, int> _videoInFlight = {};
  final Map<String, DateTime> _videoSentAt = {};

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

  /// Call member [peerId] went quiet (its network changed?) and is being
  /// reconnected; the call continues once it's back.
  bool isReconnecting(String peerId) {
    final conv = _conversation;
    if (conv == null || conv.members[peerId] != MemberState.connected) {
      return false;
    }
    final heard = conv.lastHeard[peerId];
    return heard != null && DateTime.now().difference(heard) > relinkAfter;
  }

  /// Call members that are talking right now.
  List<String> get speakers => [
    for (final id in participants)
      if (isSpeaking(id)) id,
  ];

  /// Everyone we're talking with: the connected members plus, in a group
  /// call, the members connected to them (heard through them if we can't
  /// reach them directly).
  List<String> get participants {
    final conv = _conversation;
    if (conv == null) return const [];
    final out = conv.connected.toList();
    if (conv.groupId != null) {
      for (final r in conv.rosters.values) {
        for (final id in r) {
          if (id != selfId && !out.contains(id)) out.add(id);
        }
      }
    }
    return out;
  }

  /// Whether we are talking (microphone above the voice threshold).
  bool get selfSpeaking =>
      _audioRunning && !_muted && _micLevel >= speakingThreshold;

  /// Highest volume setting: 2 = 200% (twice as loud, may distort).
  static const double maxVolume = 2;

  /// How loud the other side plays here: 0 = silent, 1 = as received
  /// (100%), up to [maxVolume]. Takes effect at once.
  double get speakerVolume => _speakerVolume;
  set speakerVolume(double v) {
    final c = v.clamp(0.0, maxVolume);
    if (c == _speakerVolume) return;
    _speakerVolume = c;
    changed();
  }

  /// How loud our microphone is sent: 0 = silent, 1 = as captured (100%),
  /// up to [maxVolume]. Takes effect at once.
  double get micVolume => _micVolume;
  set micVolume(double v) {
    final c = v.clamp(0.0, maxVolume);
    if (c == _micVolume) return;
    _micVolume = c;
    changed();
  }

  /// Security code of the encrypted link to [peerId] ("123 456"), the same
  /// on both devices unless someone intercepts the connection.
  String? securityCode(String peerId) {
    final link = _links[peerId];
    return link != null && link.secure ? link.securityCode : null;
  }

  /// The intercom password ('' = none). Only intercoms with the same
  /// password can connect; links are encrypted either way.
  String get password => _password;

  /// Changes the intercom password: hangs up and reconnects every link
  /// with the new keys.
  Future<void> setPassword(String value) async {
    if (value == _password) return;
    _password = value;
    _secret = await _deriveSecret(value);
    if (_password != value) return; // Changed again meanwhile.
    hangUp();
    for (final c in _allConnections.toList()) {
      await c.close();
    }
    for (final p in _peers.values) {
      p.wrongPassword = false;
    }
    changed();
    _retrySaved();
  }

  /// PBKDF2 takes a moment: run it off the UI isolate.
  static Future<Uint8List> _deriveSecret(String password) => password.isEmpty
      ? Future.value(networkSecret(''))
      : Isolate.run(() => networkSecret(password));

  /// We are sending camera video (see [setCamera]).
  bool get cameraOn => _cameraOn;

  /// Latest camera picture from [peerId], or null when its camera is off.
  VideoFrame? remoteVideo(String peerId) => _remoteVideo[peerId];

  /// Connected peers currently sending camera video.
  List<String> get videoPeers => [
    for (final id in _conversation?.connected ?? const <String>[])
      if (_remoteVideo.containsKey(id)) id,
  ];

  /// Called on every new picture from [peerId] and when its video stops.
  /// The Flutter app uses this to repaint only the video, not the whole UI.
  void videoChanged(String peerId) {}

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
    final known = _peers[peerId]?.name ?? _dialInfo[peerId]?.name;
    if (known != null) return known;
    for (final g in _groups.values) {
      final n = g.members[peerId];
      if (n != null && n.isNotEmpty) return n;
    }
    return 'Unknown';
  }

  /// Human readable name of [target].
  String targetName(TalkTarget t) => switch (t) {
    EveryoneTarget() => 'Everyone',
    PeerTarget(:final peerId) => displayName(peerId),
    GroupTarget(:final groupId) => _groups[groupId]?.name ?? 'Group',
  };

  // -------------------------------------------------------------- lifecycle

  Future<void> start() async {
    _secret = await _deriveSecret(_password);
    await _bindServer(preferredPort);

    if (enableDiscovery) {
      await hooks.acquireMulticastLock();
      final d = Discovery(
        selfId: selfId,
        name: _name,
        tcpPort: _server!.port,
        port: discoveryUdpPort,
      );
      d.beacons.listen(_onBeacon);
      // Kept even if it can't start now: retried when the network changes.
      _discovery = d;
      try {
        await d.start();
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
      _keepLinksAlive();
      changed();
    });
    _reconnect = Timer.periodic(reconnectInterval, (_) => _retrySaved());
    _netWatch = Timer.periodic(networkCheckInterval, (_) => _checkNetwork());
    await _checkNetwork();
    _retrySaved();
    changed();
  }

  /// Listens for peers on [port] (any free port if it's taken, e.g. a
  /// second instance on the same machine; discovery and HELLO advertise the
  /// real port, so peers still find us).
  Future<void> _bindServer(int port) async {
    ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    final boundPort = server.port;
    server.listen(
      (s) => _adopt(
        PeerConnection(s, outgoing: false, secret: _secret),
        incoming: true,
      ),
      onError: (Object e) => log('Server error: $e'),
      onDone: () => _serverClosed(server, boundPort),
    );
  }

  /// The system closed our listening socket (some phones do when the
  /// network goes away): open it again, so peers can still call us.
  void _serverClosed(ServerSocket server, int port) {
    if (_shutDown || !identical(_server, server)) return;
    log('Listening socket closed; opening it again');
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (_shutDown || !identical(_server, server)) return;
      try {
        await _bindServer(port);
      } catch (e) {
        log('Could not listen again: $e');
        return;
      }
      final now = _server!.port;
      if (now != port) {
        _discovery?.tcpPort = now;
        _discovery?.announceNow();
        for (final c in _links.values) {
          c.send(_hello());
        }
      }
    });
  }

  // ---------------------------------------------------------------- network

  /// Notices network switches (Wi-Fi ⇄ mobile data, another Wi-Fi, a VPN
  /// such as WireGuard, OpenVPN or Tailscale going up or down) by watching
  /// the device's IPv4 addresses.
  Future<void> _checkNetwork() async {
    if (_netChecking || _shutDown) return;
    _netChecking = true;
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = {
        for (final i in ifaces)
          for (final a in i.addresses) a.address,
      };
      final fingerprint = ([
        for (final i in ifaces)
          '${i.name}=${i.addresses.map((a) => a.address).join(',')}',
      ]..sort()).join(';');
      if (fingerprint == _netFingerprint) return;
      final first = _netFingerprint == null;
      _netFingerprint = fingerprint;
      _localAddresses = addresses;
      if (!first && !_shutDown) networkChanged();
    } catch (e) {
      log('Could not list network interfaces: $e');
    } finally {
      _netChecking = false;
    }
  }

  /// The network changed (also called by the platform when it knows
  /// first). Does what restarting the app used to: drops links that can't
  /// work any more, makes the others prove they still do, restarts LAN
  /// discovery on the new network and reconnects saved peers and call
  /// members right away.
  void networkChanged() {
    if (_shutDown) return;
    log('Network changed (${_localAddresses.join(', ')}): reconnecting');
    final now = DateTime.now();
    for (final c in _allConnections.toList()) {
      if (c.isClosed) continue;
      final local = c.localAddress;
      if (local != null &&
          !local.isLoopback &&
          _localAddresses.isNotEmpty &&
          !_localAddresses.contains(local.address)) {
        // Our end of it is gone: it can never work again.
        c.close();
        continue;
      }
      if (!c.verified || c.legacy) continue;
      // Routes may have moved (e.g. into a VPN): it must answer quickly.
      c.probeDeadline = now.add(probeTimeout);
      c.lastPing = now;
      c.send(Frame.empty(MessageType.ping));
    }
    // In a call, dial the members again at once instead of waiting for the
    // old links to fail: the call continues on whichever answers first.
    for (final id in _conversation?.connected.toList() ?? const <String>[]) {
      _relink(id);
    }
    // Tell the peers our new addresses (on the links that still work).
    for (final c in _links.values.toSet()) {
      if (!c.isClosed && c.verified) c.send(_hello());
    }
    _restartDiscovery();
    // Give the new network a moment (DHCP, VPN handshake), then reconnect.
    for (final delay in const [Duration(seconds: 1), Duration(seconds: 5)]) {
      Future<void>.delayed(delay, () {
        if (!_shutDown) _reconnectNow();
      });
    }
    changed();
  }

  Future<void> _restartDiscovery() async {
    final d = _discovery;
    if (d == null) return;
    try {
      // Android ties the multicast lock to the Wi-Fi it was taken on.
      await hooks.releaseMulticastLock();
      await hooks.acquireMulticastLock();
    } catch (_) {}
    if (_shutDown) return;
    try {
      if (d.running) {
        await d.restart();
      } else {
        await d.start();
      }
    } catch (e) {
      log('LAN discovery not available yet: $e');
    }
  }

  void _reconnectNow() {
    _retrySaved();
    final conv = _conversation;
    if (conv == null) return;
    for (final id in conv.connected.toList()) {
      if (!_linkAlive(id)) _relink(id);
    }
  }

  /// [id] has a link that delivered something recently.
  bool _linkAlive(String id) {
    final link = _links[id];
    return link != null &&
        !link.isClosed &&
        link.probeDeadline == null &&
        DateTime.now().difference(link.lastReceived) < relinkAfter;
  }

  /// Pings quiet links and closes the ones that stopped answering.
  void _keepLinksAlive() {
    final now = DateTime.now();
    for (final c in _allConnections.toList()) {
      if (c.isClosed || c.legacy || !c.verified) continue;
      final probe = c.probeDeadline;
      final quiet = now.difference(c.lastReceived);
      if ((probe != null && now.isAfter(probe)) || quiet > linkTimeout) {
        log(
          'Link to ${c.remoteId ?? c.remoteAddress.address} stopped '
          'answering; closing it',
        );
        c.close();
        continue;
      }
      final last = c.lastPing;
      if (quiet >= linkPingInterval &&
          (last == null || now.difference(last) >= linkPingInterval)) {
        c.lastPing = now;
        c.send(Frame.empty(MessageType.ping));
      }
    }
  }

  /// Call member [id] has gone quiet or its link broke (network switch):
  /// dials it again until it answers, the call ends, or [memberTimeout]
  /// drops it. The call stays up meanwhile and continues on the new link.
  Future<void> _relink(String id) async {
    if (_shutDown || !_relinking.add(id)) return;
    try {
      while (!_shutDown) {
        final conv = _conversation;
        if (conv == null || conv.members[id] != MemberState.connected) return;
        final p = _peers[id];
        if (p == null || _linkAlive(id)) return;
        final old = _links[id];
        try {
          final conn = await _dial(p);
          final hello = Completer<String>();
          _adopt(
            conn,
            onHello: (got) {
              if (!hello.isCompleted) hello.complete(got);
            },
          );
          final failed = conn.done.then<String>(
            (_) => throw LinkException(conn.failure ?? LinkFailure.closed),
          );
          final got = await Future.any([
            hello.future,
            failed,
          ]).timeout(const Duration(seconds: 6));
          if (got != id) {
            conn.close(); // Another device has that address now.
          } else {
            _links[id] = conn;
            p.connected = true;
            if (old != null && !identical(old, conn)) old.close();
            log('Reconnected to ${displayName(id)}');
            changed();
            return;
          }
        } on _Refused {
          // The address answers but nothing listens: its app was closed.
          if (!_linkAlive(id) &&
              (_conversation?.members[id] == MemberState.connected)) {
            _removeMember(id, reason: 'Lost connection to ${displayName(id)}');
          }
          return;
        } catch (_) {
          // Not reachable (yet); try again shortly.
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } finally {
      _relinking.remove(id);
    }
  }

  /// Opens a link to [p], trying every address it was seen at (and the
  /// saved one), a little apart so the newest wins when several work.
  Future<PeerConnection> _dial(Peer p) async {
    if (debugUnreachable.contains(p.id)) {
      throw const SocketException('unreachable (test)');
    }
    final out = <(InternetAddress, int)>[];
    void add(InternetAddress a, int port) {
      if (a.type != InternetAddressType.IPv4) return; // We listen on IPv4.
      if (!out.any((e) => e.$1 == a && e.$2 == port)) out.add((a, port));
    }

    add(p.address, p.port);
    for (final e in p.endpoints) {
      add(e.$1, e.$2);
    }
    for (final s in _saved.where((s) => s.peerId == p.id)) {
      for (final h in s.hosts) {
        for (final a in await _lookup(h)) {
          add(a, s.port);
        }
      }
    }
    // Last, the other addresses the peer told us it has.
    for (final a in p.announced) {
      add(a, p.port);
    }
    return _connectAny(out);
  }

  /// IPv4 addresses of [host] (an IP address or a name, e.g. a Tailscale
  /// MagicDNS name); empty when it can't be resolved now.
  static Future<List<InternetAddress>> _lookup(String host) async {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return [ip];
    try {
      return await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      return const [];
    }
  }

  /// Connects to the first of [endpoints] that answers. They're tried a
  /// little apart, without waiting for a dead one to time out. Throws
  /// [_Refused] if every one refused (the device is there, the app isn't).
  Future<PeerConnection> _connectAny(List<(InternetAddress, int)> endpoints) {
    if (endpoints.isEmpty) {
      return Future.error(const SocketException('No address to connect to'));
    }
    final result = Completer<PeerConnection>();
    var left = endpoints.length;
    var refused = 0;
    Object lastError = const SocketException('Unreachable');
    for (var i = 0; i < endpoints.length; i++) {
      final (address, port) = endpoints[i];
      Future<void>.delayed(Duration(milliseconds: 500 * i), () async {
        try {
          if (result.isCompleted) return;
          final c = await PeerConnection.connect(
            address,
            port,
            secret: _secret,
            timeout: const Duration(seconds: 3),
          );
          if (result.isCompleted || _shutDown) {
            c.close();
          } else {
            result.complete(c);
          }
        } catch (e) {
          lastError = e;
          if (_isRefused(e)) refused++;
        } finally {
          if (--left == 0 && !result.isCompleted) {
            result.completeError(
              refused == endpoints.length ? _Refused(lastError) : lastError,
            );
          }
        }
      });
    }
    return result.future;
  }

  static bool _isRefused(Object e) {
    if (e is! SocketException) return false;
    final code = e.osError?.errorCode;
    // ECONNREFUSED: Linux/Android 111, macOS 61, Windows WSAECONNREFUSED.
    return code == 111 || code == 61 || code == 10061;
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
    _netWatch?.cancel();
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
    String altHost = '',
  }) async {
    final h = host.trim();
    final alt = altHost.trim();
    if (h.isEmpty) throw ArgumentError('Host is empty');
    if (alt == h) throw ArgumentError('The alternate address is the same');
    if (_saved.any((s) => s.host == h && s.port == port)) {
      throw ArgumentError('$h:$port is already in the list');
    }
    final s = SavedPeer(
      key: _newKey(),
      host: h,
      port: port,
      label: label.trim(),
      altHost: alt,
    );
    _saved.add(s);
    _savedChanged();
    return _tryConnectSaved(s);
  }

  /// Saves a discovered peer (e.g. to give it a custom name).
  SavedPeer saveLivePeer(
    String peerId, {
    String label = '',
    String altHost = '',
  }) {
    final existing = _saved.where((s) => s.peerId == peerId).firstOrNull;
    if (existing != null) return existing;
    final p = _peers[peerId];
    if (p == null) throw ArgumentError('Unknown peer $peerId');
    final alt = altHost.trim();
    final s = SavedPeer(
      key: _newKey(),
      host: p.address.address,
      port: p.port,
      label: label.trim(),
      peerId: peerId,
      altHost: alt == p.address.address ? '' : alt,
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
    String? altHost,
  }) async {
    final s = _saved.where((e) => e.key == key).firstOrNull;
    if (s == null) return false;
    if (label != null) s.label = label.trim();
    final newAlt = altHost?.trim();
    if (newAlt != null &&
        newAlt.isNotEmpty &&
        newAlt == (host?.trim() ?? s.host)) {
      throw ArgumentError('The alternate address is the same');
    }
    final altChanged = newAlt != null && newAlt != s.altHost;
    if (altChanged) s.altHost = newAlt;
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
    final online = _peers[s.peerId]?.online ?? false;
    if (addressChanged || (altChanged && !online)) return _tryConnectSaved(s);
    return online;
  }

  /// Removes a saved peer from the list (a discovered peer reappears as
  /// unsaved while it's online).
  void removeSavedPeer(String key) {
    _saved.removeWhere((s) => s.key == key);
    _savedChanged();
  }

  /// Removes [entry] from the list, whether it's online or offline: it's
  /// unsaved, any call with it ends and its connections close. Nothing is
  /// blocked: if it's still on the network (discovery) or connects again,
  /// it shows up again as a new, unsaved peer.
  void removePeer(PeerEntry entry) {
    final id = entry.peerId;
    final key = entry.saved?.key;
    final before = _saved.length;
    _saved.removeWhere((s) => s.key == key || (id != null && s.peerId == id));
    if (_saved.length != before) onSavedPeersChanged?.call(savedPeers);
    if (id != null) {
      final conv = _conversation;
      if (conv != null && conv.members.containsKey(id)) {
        _send(id, Frame.empty(MessageType.close));
        _removeMember(id, quiet: true);
      }
      if (_target case PeerTarget(:final peerId) when peerId == id) {
        _target = const EveryoneTarget();
      }
      _forget(id);
    }
    changed();
  }

  // ---------------------------------------------------------------- groups

  /// Our groups, by name.
  List<Group> get groups =>
      _groups.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Group? group(String id) => _groups[id];

  /// Creates a group with us and [memberIds] and tells them (the ones
  /// offline get it the next time they connect to any member).
  Group createGroup(String name, Iterable<String> memberIds) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('The group needs a name');
    final g = Group(
      id: _newKey(),
      name: n,
      members: {selfId: _name, for (final id in memberIds) id: displayName(id)},
      updated: DateTime.now().millisecondsSinceEpoch,
      owner: selfId,
    );
    _setGroup(g);
    _shareGroup(g, g.members.keys);
    return g;
  }

  /// Renames group [id] and/or changes who is in it (we stay in it; use
  /// [leaveGroup] to leave). Every member, old and new, is told.
  void updateGroup(String id, {String? name, Iterable<String>? memberIds}) {
    final old = _groups[id];
    if (old == null) return;
    final n = name?.trim();
    if (n != null && n.isEmpty) throw ArgumentError('The group needs a name');
    final members = memberIds == null
        ? {...old.members, selfId: _name}
        : {
            selfId: _name,
            for (final m in memberIds)
              if (m != selfId)
                m: old.members[m]?.isNotEmpty ?? false
                    ? (_peers[m]?.name ?? old.members[m]!)
                    : displayName(m),
          };
    final g = old.copyWith(name: n, members: members);
    _setGroup(g);
    _shareGroup(g, {...old.members.keys, ...g.members.keys});
    // Removed members leave the call.
    final conv = _conversation;
    if (conv != null && conv.groupId == id) {
      for (final m in conv.members.keys.toList()) {
        if (!g.members.containsKey(m)) {
          _send(m, Frame.empty(MessageType.close));
          _removeMember(m, quiet: true);
        }
      }
    }
  }

  /// Leaves group [id]: the other members are told, and it's gone here.
  void leaveGroup(String id) {
    final old = _groups[id];
    if (old == null) return;
    final g = old.copyWith(members: {...old.members}..remove(selfId));
    _shareGroup(g, g.members.keys);
    _dropGroup(id);
  }

  void _dropGroup(String id) {
    _groups.remove(id);
    if (_conversation?.groupId == id) hangUp();
    if (_target == GroupTarget(id)) _target = const EveryoneTarget();
    onGroupsChanged?.call(groups);
    changed();
  }

  void _setGroup(Group g) {
    _groups[g.id] = g;
    onGroupsChanged?.call(groups);
    changed();
  }

  /// Sends [g] to the peers [to] that are online (connecting if needed).
  void _shareGroup(Group g, Iterable<String> to) {
    final frame = Frame.json(MessageType.group, g.toJson());
    for (final id in to.toSet()) {
      if (id == selfId) continue;
      final link = _links[id];
      if (link != null && !link.isClosed) {
        link.send(frame);
        continue;
      }
      final p = _peers[id];
      if (p == null || !p.online || p.outdated) continue;
      _linkTo(p).then((c) => c.send(frame), onError: (Object _) {});
    }
  }

  /// A peer sent a group's details: keep them if they're newer.
  void _onGroup(String from, Map<String, Object?> m) {
    final g = Group.fromJson(m);
    if (g == null) return;
    final old = _groups[g.id];
    if (old != null && !g.newerThan(old)) {
      // Theirs is out of date: send ours back.
      if (old.newerThan(g)) {
        _send(from, Frame.json(MessageType.group, old.toJson()));
      }
      return;
    }
    // Only a member may change a group.
    if (!(old ?? g).members.containsKey(from)) return;
    final inIt = g.members.containsKey(selfId);
    if (old == null && !inIt) return;
    if (!inIt) {
      _emit('${displayName(from)} removed you from ${g.name}');
      _dropGroup(g.id);
      return;
    }
    _setGroup(g);
    if (old == null) {
      _emit('${displayName(from)} added you to the group ${g.name}');
    }
    // Pass it on to the other members we're connected with.
    final frame = Frame.json(MessageType.group, g.toJson());
    for (final id in {...g.members.keys, ...?old?.members.keys}) {
      if (id == selfId || id == from) continue;
      _send(id, frame);
    }
  }

  /// On connect: sends [id] our groups that it's in (or had) where its copy
  /// ([theirs]: group id → updated, from its HELLO) is older or missing.
  void _syncGroups(String id, Object? theirs) {
    final known = theirs is Map ? theirs : const {};
    for (final g in _groups.values) {
      final t = known[g.id];
      final has = t is int;
      if (!has && !g.members.containsKey(id)) continue;
      if (has && t >= g.updated) continue;
      _send(id, Frame.json(MessageType.group, g.toJson()));
    }
  }

  /// Group call: tells every connected member who we're connected with,
  /// so they connect to the ones they aren't connected to yet.
  void _sendRoster(Conversation conv) {
    final gid = conv.groupId;
    if (gid == null || !identical(_conversation, conv)) return;
    final frame = Frame.json(MessageType.roster, {
      'groupId': gid,
      'members': [
        for (final id in conv.connected)
          if (_peers[id] case final p?)
            {
              'id': id,
              'name': p.name,
              'port': p.port,
              'addrs': {
                p.address.address,
                for (final a in p.announced) a.address,
              }.toList(),
            },
      ],
    });
    for (final id in conv.connected) {
      _send(id, frame);
    }
  }

  void _onRoster(String from, Map<String, Object?> m) {
    final conv = _conversation;
    if (conv == null ||
        conv.groupId == null ||
        m['groupId'] != conv.groupId ||
        conv.members[from] != MemberState.connected) {
      return;
    }
    final group = _groups[conv.groupId];
    final ids = <String>{};
    for (final e in (m['members'] as List?) ?? const []) {
      if (e is! Map) continue;
      final id = e['id'], port = e['port'], addrs = e['addrs'];
      if (id is! String || id.isEmpty) continue;
      // Only members of the group may join its call.
      if (id != selfId && !(group?.members.containsKey(id) ?? false)) continue;
      ids.add(id);
      if (id == selfId || port is! int || addrs is! List) continue;
      _dialInfo[id] = (
        name: e['name'] is String ? e['name'] as String : displayName(id),
        port: port,
        addrs: [
          for (final a in addrs.take(8))
            if (a is String) ?InternetAddress.tryParse(a),
        ].where((a) => a.type == InternetAddressType.IPv4).toList(),
      );
    }
    final before = conv.rosters[from];
    conv.rosters[from] = ids;
    _joinMissing(conv);
    if (before == null ||
        before.length != ids.length ||
        !before.containsAll(ids)) {
      changed();
    }
  }

  /// Group call: connects to members that others are connected with but we
  /// aren't (retried every [joinRetry] while they stay unreachable; meanwhile
  /// we hear them through a member that reaches both).
  void _joinMissing(Conversation conv) {
    if (!conv.isConnected) return;
    final now = DateTime.now();
    for (final r in conv.rosters.values.toList()) {
      for (final id in r) {
        if (id == selfId || conv.members.containsKey(id)) continue;
        final tried = conv.joinTried[id];
        if (tried != null && now.difference(tried) < joinRetry) continue;
        _joinMember(conv, id);
      }
    }
  }

  static const Duration joinRetry = Duration(seconds: 15);

  Future<void> _joinMember(Conversation conv, String id) async {
    conv.joinTried[id] = DateTime.now();
    final info = _dialInfo[id];
    var p = _peers[id];
    if (p == null) {
      if (info == null || info.addrs.isEmpty) return;
      // Someone we haven't met: dial where the others see it. It joins
      // the list once it answers.
      p = Peer(
        id: id,
        name: info.name,
        platform: '?',
        address: info.addrs.first,
        port: info.port,
      );
      for (final a in info.addrs.reversed) {
        p.noteEndpoint(a, info.port);
      }
      p.announced = info.addrs;
    } else if (info != null) {
      p.announced = {...p.announced, ...info.addrs}.toList();
    }
    if (p.outdated) return;
    conv.members[id] = MemberState.calling;
    conv.invitedAt[id] = DateTime.now();
    conv.joining.add(id);
    changed();
    try {
      final link = await _linkTo(p);
      if (!identical(_conversation, conv) ||
          conv.members[id] != MemberState.calling) {
        return;
      }
      link.send(
        Frame.json(MessageType.open, {
          'sampleRate': sampleRate,
          'group': true,
          'groupId': conv.groupId,
          'join': true,
        }),
      );
    } catch (_) {
      if (identical(_conversation, conv) &&
          conv.members[id] == MemberState.calling) {
        _removeMember(id, quiet: true);
      }
    }
  }

  /// Drops everything known about [id] and closes its connections.
  void _forget(String id) {
    _peers.remove(id);
    _links.remove(id);
    for (final c in _allConnections.where((c) => c.remoteId == id).toList()) {
      c.close();
    }
    _remoteVideo.remove(id);
    _peerLevel.remove(id);
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
      // Primary address first, then the alternate one.
      final endpoints = <(InternetAddress, int)>[];
      for (final h in s.hosts) {
        for (final a in await _lookup(h)) {
          if (!endpoints.any((e) => e.$1 == a)) endpoints.add((a, s.port));
        }
      }
      if (endpoints.isEmpty) return false;
      conn = await _connectAny(endpoints);
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
      final failed = conn.done.then<String>(
        (_) => throw LinkException(conn!.failure ?? LinkFailure.closed),
      );
      final id = await Future.any([
        hello.future,
        failed,
      ]).timeout(const Duration(seconds: 8));
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
          s.hosts.contains(p.address.address) &&
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
          p.address.address != s.altHost &&
          _sameNetwork(s.host, p.address.address) &&
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

  /// Whether two IPv4 addresses look like the same network (a new DHCP
  /// lease) rather than two routes to the device — a LAN address must not
  /// replace a saved VPN address (or the other way round), or the peer
  /// can't be reached any more once the user leaves that LAN.
  static bool _sameNetwork(String a, String b) {
    final x = a.split('.'), y = b.split('.');
    return x.length == 4 && y.length == 4 && x[0] == y[0] && x[1] == y[1];
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
      existing.noteEndpoint(address, port);
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
    )..noteEndpoint(address, port);
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
    if (videoReceive) 'video': true,
    // All our addresses (LAN, VPN, ...): peers try them when the one they
    // know stops answering.
    if (_localAddresses.isNotEmpty) 'addrs': _localAddresses.toList(),
    // Which groups we have and how recent: the peer sends newer copies.
    'groups': {for (final g in _groups.values) g.id: g.updated},
  });

  /// Incoming connections whose HELLO we haven't answered yet.
  final Set<PeerConnection> _helloPending = {};

  void _adopt(
    PeerConnection c, {
    void Function(String id)? onHello,
    bool incoming = false,
  }) {
    _allConnections.add(c);
    if (incoming) {
      // Say who we are once we know who's calling. Something encrypted
      // goes out at once all the same, so the caller learns right away
      // whether the passwords match. Older versions ignore a ping before
      // HELLO.
      _helloPending.add(c);
      c.send(Frame.empty(MessageType.ping));
    } else {
      c.send(_hello());
    }
    c.frames.listen((f) => _onFrame(c, f, onHello));
    c.done.then((_) => _onConnectionClosed(c));
  }

  Future<PeerConnection> _linkTo(Peer p) {
    final existing = _links[p.id];
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return _connecting[p.id] ??= () async {
      try {
        final conn = await _dial(p);
        conn.remoteId = p.id;
        _links[p.id] = conn;
        p.connected = true;
        _adopt(conn);
        // Usable once encrypted (fails e.g. on a different password).
        await conn.ready;
        return conn;
      } finally {
        _connecting.remove(p.id);
      }
    }();
  }

  void _onConnectionClosed(PeerConnection c) {
    _allConnections.remove(c);
    _helloPending.remove(c);
    if (c.failure == LinkFailure.wrongPassword) {
      // We don't know its id (its HELLO didn't decrypt): match the address.
      for (final p in _peers.values) {
        if (p.address == c.remoteAddress &&
            (!c.outgoing || p.port == c.remotePort)) {
          p.wrongPassword = true;
        }
      }
    }
    final id = c.remoteId;
    if (id != null && identical(_links[id], c)) {
      _links.remove(id);
      // Another connection to the same peer may still be alive.
      final alt = _allConnections
          .where((o) => o.remoteId == id && !o.isClosed)
          .firstOrNull;
      if (alt != null) _links[id] = alt;
      _peers[id]?.connected = alt != null;
      // A link that never worked (e.g. wrong password) was never used for
      // the call: the caller ([connect]) reports why it failed.
      final state = _conversation?.members[id];
      if (alt == null && c.verified && state != null) {
        if (state == MemberState.connected) {
          // Most likely the network changed: keep the call and dial again
          // ([memberTimeout] ends it if that doesn't work).
          _relink(id);
        } else {
          _removeMember(id, reason: 'Lost connection to ${displayName(id)}');
        }
      } else if (alt == null && c.verified) {
        // Reconnect a saved peer right away rather than at the next retry.
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          for (final s in _saved.where((s) => s.peerId == id).toList()) {
            if (!(_peers[id]?.connected ?? false)) _tryConnectSaved(s);
          }
        });
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
    if (c.legacy) {
      _onLegacyFrame(c, f, onHello);
      return;
    }
    if (f.type == MessageType.hello) {
      final m = f.json;
      final id = m['id'];
      if (id is! String || id == selfId) {
        c.close();
        return;
      }
      if (_helloPending.remove(c)) c.send(_hello());
      c.remoteId = id;
      final p = _upsertPeer(
        id: id,
        name: (m['name'] as String?) ?? 'Unknown',
        platform: (m['platform'] as String?) ?? '?',
        address: c.remoteAddress,
        port: (m['port'] as int?) ?? defaultTcpPort,
      );
      // The newest link wins: after a network switch the peer dials us
      // again while the old link may still look open here (it's dead, and
      // is closed once it stops answering pings).
      if (!c.isClosed) _links[id] = c;
      p.connected = true;
      p.version = (m['v'] as int?) ?? 1;
      p.video = m['video'] == true;
      final addrs = m['addrs'];
      if (addrs is List) {
        p.announced = [
          for (final a in addrs.take(8))
            if (a is String) ?InternetAddress.tryParse(a),
        ].where((a) => a.type == InternetAddressType.IPv4).toList();
      }
      p.wrongPassword = false;
      _resolveSaved(p);
      _syncGroups(id, m['groups']);
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
      case MessageType.video:
        _onVideo(c, id, f.payload);
      case MessageType.videoAck:
        _onVideoAck(id);
      case MessageType.group:
        _onGroup(id, f.json);
      case MessageType.roster:
        _onRoster(id, f.json);
      case MessageType.relayAudio:
        _onRelayAudio(id, f.payload);
      case MessageType.key || MessageType.sealed:
        break; // Handled by PeerConnection.
    }
  }

  /// A plaintext frame from a version without encryption: learn who it is
  /// (shown as "Needs update") and refuse calls.
  void _onLegacyFrame(
    PeerConnection c,
    Frame f,
    void Function(String id)? onHello,
  ) {
    if (f.type == MessageType.open) {
      c.sendLegacy(Frame.json(MessageType.reject, {'reason': 'unsupported'}));
      return;
    }
    if (f.type != MessageType.hello) return;
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
    p.version = (m['v'] as int?) ?? 1;
    _resolveSaved(p);
    onHello?.call(id);
    changed();
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
      GroupTarget(:final groupId) => [
        for (final id in _groups[groupId]?.members.keys ?? const <String>[])
          if (id != selfId) ?_peers[id],
      ],
    }.where((p) => p.online).toList();
    if (recipients.isEmpty) {
      _emit(switch (target) {
        EveryoneTarget() => 'Nobody is online',
        GroupTarget() when !_groups.containsKey(target.groupId) =>
          'That group no longer exists',
        GroupTarget() => 'Nobody in ${targetName(target)} is online',
        PeerTarget() => '${targetName(target)} is offline',
      }, error: true);
      return;
    }
    final outdated = recipients.where((p) => p.outdated).toList();
    for (final p in outdated) {
      _emit(
        '${displayName(p.id)} runs an older Gundil Intercom without '
        'encryption. Please update it.',
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

    final conv = Conversation(
      group: target is! PeerTarget,
      outgoing: true,
      groupId: target is GroupTarget ? target.groupId : null,
    );
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
      'groupId': ?conv.groupId,
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

  void _onOpen(String id, Map<String, Object?> m) {
    final rate = (m['sampleRate'] as int?) ?? defaultSampleRate;
    if (rate != sampleRate) {
      _send(id, Frame.json(MessageType.reject, {'reason': 'unsupported'}));
      return;
    }
    final gid = m['groupId'] is String ? m['groupId'] as String : null;
    if (gid != null && !_groups.containsKey(gid)) {
      // We left that group (or haven't got it yet).
      _send(id, Frame.json(MessageType.reject, {'reason': 'notMember'}));
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
      if (gid != null && conv.groupId == gid) {
        // Another member of the group call we're in (or starting).
        if (conv.isConnected || conv.outgoing) {
          _send(id, Frame.empty(MessageType.accept));
          _setConnected(id);
        } else {
          conv.members[id] = MemberState.ringing;
          conv.invitedAt[id] = DateTime.now();
          changed();
        }
        return;
      }
      _send(id, Frame.json(MessageType.reject, {'reason': 'busy'}));
      return;
    }
    if (m['join'] == true) {
      // A member connecting to everyone in a call we're not in.
      _send(id, Frame.json(MessageType.reject, {'reason': 'notInCall'}));
      return;
    }
    final next = Conversation(
      group: m['group'] == true || gid != null,
      outgoing: false,
      groupId: gid,
    );
    next.members[id] = MemberState.ringing;
    next.invitedAt[id] = DateTime.now();
    _conversation = next;
    if (autoAnswer) {
      accept();
    } else {
      _emit(
        gid != null
            ? '${displayName(id)} is calling ${_groups[gid]!.name}'
            : '${displayName(id)} wants to talk',
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
    _videoInFlight.remove(id);
    if (conv.ringing.isEmpty) _stopRinging();
    if (first) {
      conv.connectedAt = DateTime.now();
      _startAudio();
      if (rogerBeep && _audioRunning) _playTone(connectTone(sampleRate));
    }
    conv.joining.remove(id);
    _emit(
      '${displayName(id)} connected',
      kind: IntercomEventKind.connected,
      peerId: id,
    );
    _sendRoster(conv);
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
    conv.rosters.remove(id);
    final joining = conv.joining.remove(id);
    if (joining) quiet = true;
    _mixer.remove(id);
    _clearLevels(id);
    _videoInFlight.remove(id);
    if (_remoteVideo.remove(id) != null) videoChanged(id);
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
      if (wasConnected) _sendRoster(conv);
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
      _playTone(hangupTone(sampleRate));
      // Let the tone play out before closing the devices, unless a new
      // conversation has connected meanwhile (switching peers).
      Timer(const Duration(milliseconds: 300), () {
        if (!(_conversation?.isConnected ?? false)) _stopAudio();
      });
    } else {
      _stopAudio();
    }
    _conversation = null;
    _cameraOn = false;
    _videoInFlight.clear();
    final hadVideo = _remoteVideo.keys.toList();
    _remoteVideo.clear();
    hadVideo.forEach(videoChanged);
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
    for (final id in _remoteVideo.keys.toList()) {
      if (now.difference(_remoteVideo[id]!.receivedAt) > videoStale) {
        _remoteVideo.remove(id);
        videoChanged(id);
      }
    }
    if (conv.groupId != null) {
      for (final id in conv.relayed.keys.toList()) {
        if (now.difference(conv.relayed[id]!) > const Duration(seconds: 3)) {
          conv.relayed.remove(id);
          if (conv.members[id] != MemberState.connected) {
            _mixer.remove(id);
            _clearLevels(id);
          }
        }
      }
      if (++_rosterTick % 5 == 0) _sendRoster(conv);
      _joinMissing(conv);
    }
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
          final quiet = now.difference(conv.lastHeard[id] ?? now);
          if (quiet > relinkAfter && quiet <= memberTimeout) _relink(id);
          if (quiet > memberTimeout) {
            _removeMember(id, reason: 'Lost connection to ${displayName(id)}');
          }
      }
    }
  }

  int _rosterTick = 0;

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
    if (conv.groupId != null) _relay(conv, id, payload);
  }

  /// Group call: forwards [src]'s audio to the members that can't reach
  /// [src] directly. Of all members connected to both, the one with the
  /// lowest id does it, so it arrives once.
  void _relay(Conversation conv, String src, Uint8List pcm) {
    final srcRoster = conv.rosters[src] ?? const <String>{};
    Frame? frame;
    for (final m in conv.connected) {
      if (m == src) continue;
      final r = conv.rosters[m];
      // Unknown yet (or an older version), or it hears [src] itself.
      if (r == null || r.contains(src)) continue;
      var relay = selfId;
      for (final c in srcRoster) {
        if (c != m && r.contains(c) && c.compareTo(relay) < 0) relay = c;
      }
      if (relay != selfId) continue;
      frame ??= () {
        final idBytes = utf8.encode(src);
        return Frame(
          MessageType.relayAudio,
          Uint8List(1 + idBytes.length + pcm.length)
            ..[0] = idBytes.length
            ..setRange(1, 1 + idBytes.length, idBytes)
            ..setRange(
              1 + idBytes.length,
              1 + idBytes.length + pcm.length,
              pcm,
            ),
        );
      }();
      _send(m, frame);
    }
  }

  void _onRelayAudio(String from, Uint8List payload) {
    final conv = _conversation;
    if (conv == null ||
        conv.groupId == null ||
        conv.members[from] != MemberState.connected ||
        payload.isEmpty) {
      return;
    }
    final n = payload[0];
    if (n == 0 || payload.length < 1 + n) return;
    final src = utf8.decode(payload.sublist(1, 1 + n), allowMalformed: true);
    // Ours echoed back, or someone we hear directly anyway.
    if (src == selfId || conv.members[src] == MemberState.connected) return;
    final now = DateTime.now();
    conv.relayed[src] = now;
    final samples = bytesToPcm(Uint8List.sublistView(payload, 1 + n));
    final level = rmsLevel(samples);
    _peerLevel[src] = level;
    _levelAt[src] = now;
    if (level >= speakingThreshold) _voiceAt[src] = now;
    if (_audioRunning) _mixer.add(src, samples);
  }

  // ------------------------------------------------------------------ video

  /// Turns sending camera video on or off. The app's camera calls this, then
  /// feeds pictures with [sendVideoFrame]. Turning it off tells the peers
  /// at once; it also goes off by itself when the conversation ends.
  void setCamera(bool on) {
    if (on && !inConversation) on = false;
    if (on == _cameraOn) return;
    _cameraOn = on;
    if (!on) {
      final off = Frame(MessageType.video, VideoFrame.encodeOff());
      for (final id in _conversation?.connected ?? const <String>[]) {
        if (_peers[id]?.video ?? false) _send(id, off);
      }
      _videoInFlight.clear();
    }
    changed();
  }

  /// Sends one JPEG camera picture to every connected member that can show
  /// video. A member that hasn't acknowledged the previous pictures yet
  /// skips this one (keeps the line responsive on slow Wi-Fi). Returns how
  /// many members it was sent to.
  int sendVideoFrame(Uint8List jpeg, {int rotation = 0}) {
    final conv = _conversation;
    if (conv == null || !_cameraOn) return 0;
    // Room for the rotation byte and the encryption overhead.
    if (jpeg.length + 1 + sealOverhead > maxFramePayload) return 0;
    final now = DateTime.now();
    Frame? frame;
    var sent = 0;
    for (final id in conv.connected) {
      if (!(_peers[id]?.video ?? false)) continue;
      var pending = _videoInFlight[id] ?? 0;
      if (pending >= maxVideoInFlight) {
        // Acknowledgements normally take milliseconds; after this long they
        // are not coming (e.g. the peer just restarted its call).
        final at = _videoSentAt[id];
        if (at != null && now.difference(at) < const Duration(seconds: 2)) {
          continue;
        }
        pending = 0;
      }
      frame ??= Frame(
        MessageType.video,
        VideoFrame.encode(jpeg, rotation: rotation),
      );
      _send(id, frame);
      _videoInFlight[id] = pending + 1;
      _videoSentAt[id] = now;
      sent++;
    }
    return sent;
  }

  void _onVideo(PeerConnection c, String id, Uint8List payload) {
    // Always acknowledge, even when we no longer want it, so the sender's
    // flow control never stalls.
    c.send(Frame.empty(MessageType.videoAck));
    final conv = _conversation;
    if (!videoReceive ||
        conv == null ||
        conv.members[id] != MemberState.connected) {
      return;
    }
    final frame = VideoFrame.decode(payload);
    if (frame == null) {
      if (_remoteVideo.remove(id) != null) {
        videoChanged(id);
        changed();
      }
      return;
    }
    final isNew = !_remoteVideo.containsKey(id);
    _remoteVideo[id] = frame;
    videoChanged(id);
    if (isNew) changed();
  }

  void _onVideoAck(String id) {
    final n = _videoInFlight[id];
    if (n != null && n > 0) _videoInFlight[id] = n - 1;
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
    hooks.startCallAudio();
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
        applyGain(mixed, _speakerVolume);
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
          // After echo suppression, which compares the raw mic level.
          applyGain(mic, _micVolume);
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
    // Never quieter than half volume, so a call can't be missed.
    void ring() =>
        _playTone(ringTone(sampleRate), gain: math.max(_speakerVolume, 0.5));
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

  /// Plays a tone at the speaker volume (or [gain]).
  void _playTone(Int16List tone, {double? gain}) {
    applyGain(tone, gain ?? _speakerVolume);
    audio.play(tone);
  }

  /// Scales [samples] in place by [gain], clipping to 16 bit.
  static void applyGain(Int16List samples, double gain) {
    if (gain == 1) return;
    final g = (gain * 4096).round(); // Fixed point, 12 bits.
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i] * g) >> 12;
      samples[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
    }
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

/// Every address of a peer refused the connection: the device is there but
/// the intercom isn't running on it.
class _Refused implements Exception {
  _Refused(this.error);
  final Object error;

  @override
  String toString() => '$error';
}
