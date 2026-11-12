import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

IntercomCore node(String id, String name, FakeAudioEngine audio) =>
    IntercomCore(
      selfId: id,
      name: name,
      audio: audio,
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
      echoSuppression: false,
    );

/// A TCP relay standing in for a network path (e.g. the Wi-Fi). [cut] makes
/// it drop everything without closing anything — what a link looks like
/// after the phone switched to mobile data: open, but silent forever.
class Relay {
  Relay._(this._server, this.target) {
    _server.listen((client) async {
      final Socket up;
      try {
        up = await Socket.connect(InternetAddress.loopbackIPv4, target);
      } catch (_) {
        client.destroy();
        return;
      }
      _sockets.addAll([client, up]);
      client.listen(
        (d) {
          if (!_cut) up.add(d);
        },
        onDone: up.destroy,
        onError: (_) => up.destroy(),
      );
      up.listen(
        (d) {
          if (!_cut) client.add(d);
        },
        onDone: client.destroy,
        onError: (_) => client.destroy(),
      );
    });
  }

  static Future<Relay> start(int target) async =>
      Relay._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), target);

  final ServerSocket _server;
  final int target;
  final List<Socket> _sockets = [];
  bool _cut = false;

  int get port => _server.port;

  void cut() => _cut = true;

  Future<void> close() async {
    await _server.close();
    for (final s in _sockets) {
      s.destroy();
    }
  }
}

void main() {
  late FakeAudioEngine aliceAudio, bobAudio;
  late IntercomCore alice, bob;
  late Relay wifi;
  late List<String> aliceEvents;

  setUp(() async {
    aliceAudio = FakeAudioEngine();
    bobAudio = FakeAudioEngine();
    alice = node('alice-id', 'Alice', aliceAudio);
    bob = node('bob-id', 'Bob', bobAudio);
    await Future.wait([alice.start(), bob.start()]);
    aliceEvents = [];
    alice.events.listen((e) => aliceEvents.add(e.message));
    // Alice reaches Bob through the "Wi-Fi" first.
    wifi = await Relay.start(bob.listenPort!);
    expect(await alice.addSavedPeer(host: '127.0.0.1', port: wifi.port), true);
    await eventually(() => bob.peer('alice-id')?.connected ?? false);
  });

  tearDown(() async {
    await wifi.close();
    await Future.wait([alice.shutdown(), bob.shutdown()]);
  });

  test('a link that went silent is dropped after a network change', () async {
    expect(alice.peer('bob-id')!.connected, isTrue);
    wifi.cut();
    alice.networkChanged();
    // Without the check it would look connected for many minutes. With it,
    // the link has [IntercomCore.probeTimeout] to answer, then the next
    // housekeeping tick (every second) closes it.
    await eventually(
      () => !alice.peer('bob-id')!.connected,
      timeout: IntercomCore.probeTimeout + const Duration(seconds: 6),
    );
  });

  test('a call survives a network switch', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    aliceAudio.inject(Int16List.fromList(List.filled(1600, 11)));
    await eventually(() => bobAudio.played.contains(11));

    // The Wi-Fi goes away. Bob is still reachable another way (here:
    // directly), like over mobile data and a VPN.
    wifi.cut();
    alice.networkChanged();

    // Talk until it gets through again, both ways.
    final end = DateTime.now().add(const Duration(seconds: 12));
    while (!(bobAudio.played.contains(33) && aliceAudio.played.contains(44))) {
      if (DateTime.now().isAfter(end)) fail('audio did not resume');
      aliceAudio.inject(Int16List.fromList(List.filled(1600, 33)));
      bobAudio.inject(Int16List.fromList(List.filled(1600, 44)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(alice.inConversation && bob.inConversation, isTrue);
    expect(alice.memberState('bob-id'), MemberState.connected);
    expect(bob.memberState('alice-id'), MemberState.connected);
    await eventually(() => !alice.isReconnecting('bob-id'));
    expect(aliceEvents.where((m) => m.contains('Lost connection')), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a member whose app is gone is still dropped quickly', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    // Bob vanishes without hanging up (killed), and so does the route.
    wifi.cut();
    await bob.shutdown();
    await wifi.close();
    // Every address refuses: Bob's app isn't running, nothing to wait for.
    await eventually(() => alice.conversation == null);
    expect(aliceEvents.where((m) => m.contains('Lost connection')), isNotEmpty);
    bob = node('bob-id', 'Bob', bobAudio);
    await bob.start();
  });
}
