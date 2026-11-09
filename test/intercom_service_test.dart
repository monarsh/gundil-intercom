import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/audio_engine.dart';
import 'package:p2p_intercom/src/intercom_service.dart';
import 'package:p2p_intercom/src/models.dart';

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
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.addManualPeer('127.0.0.1', port: carol.listenPort!);
    await carol.addManualPeer('127.0.0.1', port: bob.listenPort!);
  });

  tearDown(() async {
    await Future.wait([alice.shutdown(), bob.shutdown(), carol.shutdown()]);
  });

  test('peers learn each other on both sides', () async {
    expect(alice.peer('bob-id')!.name, 'Bob');
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

  test('rmsLevel and roger tone', () {
    expect(IntercomService.rmsLevel(Int16List(100)), 0);
    expect(IntercomService.rmsLevel(tone(100, 32767)), closeTo(1, 0.01));
    final beep = IntercomService.rogerTone(16000);
    expect(beep.length, 16000 * 140 ~/ 1000);
    expect(beep.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(5000));
  });
}
