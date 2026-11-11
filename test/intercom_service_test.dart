import 'dart:async';
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

/// [n] samples of a constant value: easy to spot in what a peer played.
Int16List voice(int n, int value) => tone(n, value);

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
        echoSuppression: false,
        // Carol stands in for the headless node, which shows no video.
        videoReceive: id != 'carol-id',
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

  test('connect opens two-way audio; the other side auto-answers', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    expect(alice.memberState('bob-id'), MemberState.connected);
    expect(bob.memberState('alice-id'), MemberState.connected);
    expect(aliceAudio.capturing && aliceAudio.playing, isTrue);
    expect(bobAudio.capturing && bobAudio.playing, isTrue);

    // Both directions at the same time — no button to hold.
    aliceAudio.inject(voice(1600, 11));
    bobAudio.inject(voice(1600, 22));
    await eventually(
      () => bobAudio.played.contains(11) && aliceAudio.played.contains(22),
    );
    // Carol was not involved.
    expect(carol.conversation, isNull);

    alice.hangUp();
    expect(alice.conversation, isNull);
    await eventually(() => bob.conversation == null);
    expect(aliceAudio.capturing || bobAudio.capturing, isFalse);
  });

  test('either side can hang up', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.inConversation);
    bob.hangUp();
    await eventually(() => alice.conversation == null);
  });

  test('auto-answer off: rings until accepted', () async {
    bob.autoAnswer = false;
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.ringing);
    expect(alice.memberState('bob-id'), MemberState.calling);
    expect(bobAudio.capturing, isFalse); // mic stays off while ringing
    await bob.accept();
    await eventually(() => alice.inConversation && bob.inConversation);
    aliceAudio.inject(voice(1600, 5));
    await eventually(() => bobAudio.played.contains(5));
  });

  test('auto-answer off: declining tells the caller', () async {
    bob.autoAnswer = false;
    final events = <String>[];
    final sub = alice.events.listen((e) => events.add(e.message));
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.ringing);
    bob.decline();
    await eventually(() => alice.conversation == null);
    await eventually(() => events.isNotEmpty);
    expect(events.last, contains('declined'));
    await sub.cancel();
  });

  test('a busy peer refuses a second caller', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.inConversation);
    final events = <String>[];
    final sub = carol.events.listen((e) => events.add(e.message));
    await carol.connect(const PeerTarget('bob-id'));
    await eventually(() => carol.conversation == null);
    await eventually(() => events.isNotEmpty);
    expect(events.last, contains('busy'));
    expect(bob.memberState('alice-id'), MemberState.connected);
    await sub.cancel();
  });

  test('calling each other at the same moment connects', () async {
    await Future.wait([
      alice.connect(const PeerTarget('bob-id')),
      bob.connect(const PeerTarget('alice-id')),
    ]);
    await eventually(() => alice.inConversation && bob.inConversation);
  });

  test('Everyone: hub hears all members mixed, members hear the hub', () async {
    await alice.connect(const EveryoneTarget());
    await eventually(
      () =>
          alice.memberState('bob-id') == MemberState.connected &&
          alice.memberState('carol-id') == MemberState.connected,
    );
    expect(alice.conversation!.group, isTrue);
    // Feed all three microphones continuously, like live speech.
    final feeder = Timer.periodic(const Duration(milliseconds: 20), (_) {
      bobAudio.inject(voice(320, 100));
      carolAudio.inject(voice(320, 1000));
      aliceAudio.inject(voice(320, 7));
    });
    addTearDown(feeder.cancel);
    // Mixed: Alice hears Bob + Carol summed in the same samples.
    await eventually(() => aliceAudio.played.contains(1100));
    await eventually(
      () => bobAudio.played.contains(7) && carolAudio.played.contains(7),
    );
    // Members only talk to the hub, not to each other.
    expect(bob.memberState('carol-id'), isNull);
  });

  test('switching to another peer hangs up the first', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.inConversation);
    await alice.connect(const PeerTarget('carol-id'));
    await eventually(() => bob.conversation == null);
    await eventually(() => carol.inConversation && alice.inConversation);
    expect(alice.conversation!.members.keys, ['carol-id']);
  });

  test('the receiving side sees who is speaking', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    expect(alice.isSpeaking('bob-id'), isFalse);

    // Quiet background noise / echo does not count as speaking.
    bobAudio.inject(voice(1600, 30));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(alice.isSpeaking('bob-id'), isFalse);

    // Bob talks: Alice sees him speaking, with a level.
    final feeder = Timer.periodic(const Duration(milliseconds: 20), (_) {
      bobAudio.inject(voice(320, 5000));
    });
    await eventually(() => alice.isSpeaking('bob-id'));
    expect(alice.speakers, ['bob-id']);
    expect(alice.peerLevel('bob-id'), greaterThan(0.5));
    expect(bob.isSpeaking('alice-id'), isFalse); // Alice is silent
    expect(bob.selfSpeaking, isTrue);

    // Bob stops: the indicator clears after the hold time.
    feeder.cancel();
    await eventually(() => !alice.isSpeaking('bob-id'));
    expect(alice.speakers, isEmpty);
  });

  test('connect / hang-up events name the peer', () async {
    final aliceEvents = <IntercomEvent>[];
    final bobEvents = <IntercomEvent>[];
    final s1 = alice.events.listen(aliceEvents.add);
    final s2 = bob.events.listen(bobEvents.add);
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(
      () => bobEvents.any((e) => e.kind == IntercomEventKind.connected),
    );
    final c = bobEvents.firstWhere(
      (e) => e.kind == IntercomEventKind.connected,
    );
    expect(c.peerId, 'alice-id');
    expect(c.message, 'Alice connected');

    bob.hangUp();
    await eventually(
      () => aliceEvents.any((e) => e.kind == IntercomEventKind.disconnected),
    );
    final d = aliceEvents.firstWhere(
      (e) => e.kind == IntercomEventKind.disconnected,
    );
    expect(d.peerId, 'bob-id');
    expect(d.message, contains('Bob hung up'));
    await s1.cancel();
    await s2.cancel();
  });

  test('mute stops sending the microphone', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.inConversation);
    alice.toggleMute();
    aliceAudio.inject(voice(1600, 9));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bobAudio.played.contains(9), isFalse);
    alice.toggleMute();
    aliceAudio.inject(voice(1600, 9));
    await eventually(() => bobAudio.played.contains(9));
  });

  test('microphone and speaker volume scale the audio', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => bob.inConversation);
    // Alice's mic at 50%: Bob receives half the level.
    alice.micVolume = 0.5;
    aliceAudio.inject(voice(1600, 4000));
    await eventually(() => bobAudio.played.contains(2000));
    expect(bobAudio.played.contains(4000), isFalse);
    // Bob's speaker at 200% doubles what he plays.
    bob.speakerVolume = 2;
    aliceAudio.inject(voice(1600, 1000));
    await eventually(() => bobAudio.played.contains(1000)); // 500 * 2
    // 0% is silent; values are clamped to 0..200%.
    bob.speakerVolume = 5;
    expect(bob.speakerVolume, IntercomCore.maxVolume);
    alice.micVolume = -1;
    expect(alice.micVolume, 0);
  });

  test('applyGain clips instead of wrapping around', () {
    final s = Int16List.fromList([1000, -1000, 30000, -30000, 0]);
    IntercomCore.applyGain(s, 2);
    expect(s, [2000, -2000, 32767, -32768, 0]);
    IntercomCore.applyGain(s, 0);
    expect(s, [0, 0, 0, 0, 0]);
  });

  group('camera video', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);

    test('only during a call; the peer sees the picture', () async {
      alice.setCamera(true);
      expect(alice.cameraOn, isFalse, reason: 'no call yet');
      expect(alice.sendVideoFrame(jpeg), 0);

      await alice.connect(const PeerTarget('bob-id'));
      await eventually(() => alice.inConversation && bob.inConversation);
      expect(alice.peer('bob-id')!.video, isTrue);
      alice.setCamera(true);
      expect(alice.cameraOn, isTrue);
      expect(alice.sendVideoFrame(jpeg, rotation: 3), 1);
      await eventually(() => bob.remoteVideo('alice-id') != null);
      expect(bob.remoteVideo('alice-id')!.jpeg, jpeg);
      expect(bob.remoteVideo('alice-id')!.rotation, 3);
      expect(bob.videoPeers, ['alice-id']);
      expect(bob.videoTick.value, greaterThan(0));
    });

    test('turning the camera off clears the picture at once', () async {
      await alice.connect(const PeerTarget('bob-id'));
      await eventually(() => alice.inConversation && bob.inConversation);
      alice.setCamera(true);
      alice.sendVideoFrame(jpeg);
      await eventually(() => bob.remoteVideo('alice-id') != null);
      alice.setCamera(false);
      await eventually(() => bob.remoteVideo('alice-id') == null);
      expect(alice.sendVideoFrame(jpeg), 0);
    });

    test('flow control: at most a few unacknowledged pictures', () async {
      await alice.connect(const PeerTarget('bob-id'));
      await eventually(() => alice.inConversation && bob.inConversation);
      alice.setCamera(true);
      var sent = 0;
      for (var i = 0; i < 10; i++) {
        sent += alice.sendVideoFrame(jpeg);
      }
      expect(sent, IntercomCore.maxVideoInFlight);
      // Acks arrive: sending resumes.
      await eventually(() => alice.sendVideoFrame(jpeg) == 1);
    });

    test('hanging up turns the camera off on both sides', () async {
      await alice.connect(const PeerTarget('bob-id'));
      await eventually(() => alice.inConversation && bob.inConversation);
      bob.setCamera(true);
      bob.sendVideoFrame(jpeg);
      await eventually(() => alice.remoteVideo('bob-id') != null);
      bob.hangUp();
      expect(bob.cameraOn, isFalse);
      await eventually(() => !alice.inConversation);
      expect(alice.remoteVideo('bob-id'), isNull);
    });

    test('peers that cannot show video are not sent any', () async {
      await alice.connect(const PeerTarget('carol-id'));
      await eventually(() => alice.inConversation && carol.inConversation);
      expect(alice.peer('carol-id')!.video, isFalse);
      alice.setCamera(true);
      expect(alice.sendVideoFrame(jpeg), 0);
    });
  });

  test('connecting to an offline peer reports an error', () async {
    final events = <String>[];
    final sub = alice.events.listen((e) => events.add(e.message));
    await bob.shutdown();
    await eventually(() => !alice.peer('bob-id')!.online);
    await alice.connect(const PeerTarget('bob-id'));
    expect(alice.conversation, isNull);
    await eventually(() => events.isNotEmpty);
    expect(events.single, contains('offline'));
    await sub.cancel();
    bob = node('bob-id', 'Bob', bobAudio);
    await bob.start();
  });

  test('a member that vanishes is dropped', () async {
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation);
    await bob.shutdown();
    await eventually(() => alice.conversation == null);
    bob = node('bob-id', 'Bob', bobAudio);
    await bob.start();
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

  test('rmsLevel and tones', () {
    expect(IntercomCore.rmsLevel(Int16List(100)), 0);
    expect(IntercomCore.rmsLevel(tone(100, 32767)), closeTo(1, 0.01));
    for (final t in [
      IntercomCore.connectTone(16000),
      IntercomCore.hangupTone(16000),
      IntercomCore.ringTone(16000),
    ]) {
      expect(t, isNotEmpty);
      expect(t.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(5000));
    }
  });
}
