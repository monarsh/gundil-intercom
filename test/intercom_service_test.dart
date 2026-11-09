import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/intercom_service.dart';

/// Polls [condition] until true or fails after [timeout].
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

Int16List tone(int n, int value) => Int16List.fromList(List.filled(n, value));

void main() {
  late IntercomService alice, bob, carol;
  late FakeAudioEngine aliceAudio, bobAudio, carolAudio;

  IntercomService node(String id, String name, FakeAudioEngine audio) =>
      IntercomService(
        selfId: id,
        name: name,
        audio: audio,
        preferredPort: 0, // any free port
        enableDiscovery: false,
        rogerBeep: false,
      );

  setUp(() async {
    aliceAudio = FakeAudioEngine();
    bobAudio = FakeAudioEngine();
    carolAudio = FakeAudioEngine();
    alice = node('alice-id', 'Alice', aliceAudio);
    bob = node('bob-id', 'Bob', bobAudio);
    carol = node('carol-id', 'Carol', carolAudio);
    await Future.wait([alice.start(), bob.start(), carol.start()]);
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: carol.listenPort!),
      isTrue,
    );
    expect(
      await carol.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
  });

  tearDown(() async {
    await Future.wait([alice.shutdown(), bob.shutdown(), carol.shutdown()]);
  });

  test('peers learn each other on both sides', () async {
    expect(alice.peer('bob-id')!.name, 'Bob');
    expect(alice.entries.map((e) => e.name), containsAll(['Bob', 'Carol']));
    await eventually(() => bob.peer('alice-id')?.name == 'Alice');
    await eventually(() => bob.peer('carol-id')?.online ?? false);
  });

  test('push-to-talk to one peer plays instantly, no answer needed', () async {
    alice.selectTarget(const PeerTarget('bob-id'));
    await alice.startTalking();
    expect(alice.transmitting, isTrue);
    expect(aliceAudio.capturing, isTrue);

    await eventually(() => bob.incoming?.peerId == 'alice-id');
    expect(bob.incoming!.group, isFalse);
    expect(bobAudio.playing, isTrue);

    final voice = Int16List.fromList(
      List.generate(320, (i) => (i * 97) % 20000 - 10000),
    );
    aliceAudio.inject(voice);
    await eventually(() => bobAudio.played.length >= 320);
    expect(bobAudio.played.sublist(0, 320), voice);

    // Carol was not addressed.
    expect(carol.incoming, isNull);
    expect(carolAudio.played, isEmpty);

    alice.stopTalking();
    expect(alice.transmitting, isFalse);
    expect(aliceAudio.capturing, isFalse);
    await eventually(() => bob.incoming == null);
  });

  test('Everyone channel reaches all online peers', () async {
    alice.selectTarget(const EveryoneTarget());
    await alice.startTalking();
    await eventually(
      () => bob.incoming?.peerId == 'alice-id' && carol.incoming != null,
    );
    expect(bob.incoming!.group, isTrue);
    aliceAudio.inject(tone(160, 42));
    await eventually(
      () => bobAudio.played.length >= 160 && carolAudio.played.length >= 160,
    );
    alice.stopTalking();
    await eventually(() => bob.incoming == null && carol.incoming == null);
  });

  test('switching channel while talking stops the transmission', () async {
    alice.selectTarget(const PeerTarget('bob-id'));
    await alice.startTalking();
    await eventually(() => bob.incoming != null);
    alice.selectTarget(const PeerTarget('carol-id'));
    expect(alice.transmitting, isFalse);
    await eventually(() => bob.incoming == null);

    await alice.startTalking();
    await eventually(() => carol.incoming?.peerId == 'alice-id');
    expect(bob.incoming, isNull);
  });

  test('second talker is ignored while the channel is busy', () async {
    alice.selectTarget(const PeerTarget('bob-id'));
    carol.selectTarget(const PeerTarget('bob-id'));
    await alice.startTalking();
    await eventually(() => bob.incoming?.peerId == 'alice-id');

    await carol.startTalking();
    carolAudio.inject(tone(160, 7));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(bob.incoming!.peerId, 'alice-id');
    expect(bobAudio.played.contains(7), isFalse);

    // Once Alice releases, Carol's next press gets through.
    alice.stopTalking();
    carol.stopTalking();
    await eventually(() => bob.incoming == null);
    await carol.startTalking();
    await eventually(() => bob.incoming?.peerId == 'carol-id');
  });

  test('half-duplex: incoming audio is muted while we transmit', () async {
    alice.selectTarget(const PeerTarget('bob-id'));
    bob.selectTarget(const PeerTarget('alice-id'));
    await alice.startTalking();
    await eventually(() => bob.incoming != null);
    await bob.startTalking();
    aliceAudio.inject(tone(160, 5));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(bobAudio.played, isEmpty);
  });

  test('talking to an offline peer reports an error', () async {
    final events = <String>[];
    final sub = alice.events.listen((e) => events.add(e.message));
    alice.selectTarget(const PeerTarget('bob-id'));
    await bob.shutdown();
    await eventually(() => !alice.peer('bob-id')!.online);
    await alice.startTalking();
    expect(alice.transmitting, isFalse);
    await eventually(() => events.isNotEmpty);
    expect(events.single, contains('offline'));
    await sub.cancel();
    bob = node('bob-id', 'Bob', bobAudio);
    await bob.start();
  });

  test('receiver drops a talker that vanishes mid-transmission', () async {
    alice.selectTarget(const PeerTarget('bob-id'));
    await alice.startTalking();
    await eventually(() => bob.incoming?.peerId == 'alice-id');
    await alice.shutdown();
    await eventually(() => bob.incoming == null);
    alice = node('alice-id', 'Alice', aliceAudio);
    await alice.start();
  });

  group('saved peers', () {
    Future<int> freePort() async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = s.port;
      await s.close();
      return p;
    }

    IntercomService withSaved(
      List<SavedPeer> saved,
      void Function(List<SavedPeer>) onChange,
    ) => IntercomService(
      selfId: 'dave-id',
      name: 'Dave',
      audio: FakeAudioEngine(),
      preferredPort: 0,
      enableDiscovery: false,
      savedPeers: saved,
      onSavedPeersChanged: onChange,
      reconnectInterval: const Duration(milliseconds: 200),
    );

    test(
      'offline peer stays in the list and connects when it appears',
      () async {
        List<SavedPeer> persisted = [];
        final dave = withSaved([], (l) => persisted = l);
        await dave.start();
        final port = await freePort();

        final online = await dave.addSavedPeer(
          host: '127.0.0.1',
          port: port,
          label: 'Gate',
        );
        expect(online, isFalse);
        expect(persisted.single.label, 'Gate');
        final e = dave.entries.single;
        expect(e.name, 'Gate');
        expect(e.online, isFalse);
        expect(e.peerId, isNull);

        // The peer comes online later: background retry links it.
        final gate = IntercomService(
          selfId: 'gate-id',
          name: 'Gate PC',
          audio: FakeAudioEngine(),
          preferredPort: port,
          enableDiscovery: false,
        );
        await gate.start();
        await eventually(() => dave.entries.single.online);
        expect(dave.entries.single.peerId, 'gate-id');
        expect(dave.entries.single.name, 'Gate'); // label wins
        expect(persisted.single.peerId, 'gate-id');
        expect(dave.displayName('gate-id'), 'Gate');
        await gate.shutdown();
        await eventually(() => !dave.entries.single.online);
        expect(dave.entries.length, 1); // still listed while offline
        await dave.shutdown();
      },
    );

    test('saved peers survive an app restart', () async {
      List<SavedPeer> persisted = [];
      final first = withSaved([], (l) => persisted = l);
      await first.start();
      await first.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!);
      await first.addSavedPeer(
        host: '10.255.255.1',
        port: 47801,
        label: 'Garage',
      );
      await first.shutdown();

      // Round-trip through JSON like Settings does.
      final restored = persisted
          .map((s) => SavedPeer.fromJson(s.toJson())!)
          .toList();
      final second = withSaved(restored, (l) => persisted = l);
      await second.start();
      final names = second.entries.map((e) => e.name).toSet();
      expect(names, containsAll(['Garage']));
      expect(second.entries.length, 2);
      await eventually(
        () => second.entries.any((e) => e.peerId == 'bob-id' && e.online),
      );
      expect(
        second.entries.firstWhere((e) => e.name == 'Garage').online,
        isFalse,
      );
      await second.shutdown();
    });

    test('edit label and address; remove', () async {
      final key = alice.entries
          .firstWhere((e) => e.peerId == 'bob-id')
          .saved!
          .key;

      await alice.updateSavedPeer(key, label: 'Front desk');
      expect(alice.displayName('bob-id'), 'Front desk');
      expect(alice.targetName(const PeerTarget('bob-id')), 'Front desk');

      // Point the same entry at Carol's address instead.
      final carolKey = alice.entries
          .firstWhere((e) => e.peerId == 'carol-id')
          .saved!
          .key;
      alice.removeSavedPeer(carolKey);
      final ok = await alice.updateSavedPeer(
        key,
        host: '127.0.0.1',
        port: carol.listenPort!,
      );
      expect(ok, isTrue);
      final edited = alice.entries.firstWhere((e) => e.saved?.key == key);
      expect(edited.peerId, 'carol-id');
      expect(edited.name, 'Front desk');

      // Bob is still connected, so he shows as an unsaved live peer.
      expect(
        alice.entries.any((e) => e.peerId == 'bob-id' && !e.isSaved),
        isTrue,
      );

      alice.removeSavedPeer(key);
      expect(alice.savedPeers, isEmpty);
    });

    test('saved address follows the peer to a new IP/port', () async {
      List<SavedPeer> persisted = [];
      // Saved from an earlier session when Bob was on another port.
      final stale = SavedPeer(
        key: 'k1',
        host: '127.0.0.1',
        port: await freePort(),
        label: 'Bob desk',
        peerId: 'bob-id',
      );
      final dave = withSaved([stale], (l) => persisted = l);
      await dave.start();
      expect(dave.entries.single.online, isFalse);
      expect(dave.entries.single.platform, '?');

      // Bob reaches Dave (e.g. via discovery or his own saved list).
      await bob.addSavedPeer(host: '127.0.0.1', port: dave.listenPort!);
      await eventually(() => dave.entries.single.online);
      expect(dave.entries.length, 1);
      expect(dave.entries.single.name, 'Bob desk');
      expect(persisted.single.port, bob.listenPort);
      expect(persisted.single.platform, Platform.operatingSystem);
      await dave.shutdown();
    });

    test('duplicate addresses are rejected', () async {
      expect(
        () => alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
        throwsArgumentError,
      );
    });

    test('a discovered peer can be kept and renamed', () async {
      // Bob only knows Alice because she connected to him.
      await eventually(() => bob.entries.any((e) => e.peerId == 'alice-id'));
      final e = bob.entries.firstWhere((e) => e.peerId == 'alice-id');
      expect(e.isSaved, isFalse);
      bob.saveLivePeer('alice-id', label: 'Boss');
      final saved = bob.entries.firstWhere((e) => e.peerId == 'alice-id');
      expect(saved.isSaved, isTrue);
      expect(saved.name, 'Boss');
      expect(saved.saved!.host, '127.0.0.1');
      expect(bob.entries.where((e) => e.peerId == 'alice-id').length, 1);
    });
  });

  test('rmsLevel and roger tone', () {
    expect(IntercomCore.rmsLevel(Int16List(100)), 0);
    expect(IntercomCore.rmsLevel(tone(100, 32767)), closeTo(1, 0.01));
    final beep = IntercomCore.rogerTone(16000);
    expect(beep.length, 16000 * 140 ~/ 1000);
    expect(beep.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(5000));
  });
}
