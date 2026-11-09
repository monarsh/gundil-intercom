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
      );

  setUp(() async {
    aliceAudio = FakeAudioEngine();
    bobAudio = FakeAudioEngine();
    carolAudio = FakeAudioEngine();
    alice = node('alice-id', 'Alice', aliceAudio);
    bob = node('bob-id', 'Bob', bobAudio);
    carol = node('carol-id', 'Carol', carolAudio);
    await Future.wait([alice.start(), bob.start(), carol.start()]);
  });

  tearDown(() async {
    await Future.wait([alice.shutdown(), bob.shutdown(), carol.shutdown()]);
  });

  test('manual add exchanges identities on both sides', () async {
    final p = await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    expect(p.id, 'bob-id');
    expect(p.name, 'Bob');
    expect(p.online, isTrue);
    await eventually(() => bob.peer('alice-id')?.name == 'Alice');
  });

  test('text chat both ways', () async {
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.sendText('bob-id', 'hello bob');
    await eventually(() => bob.peer('alice-id')?.messages.length == 1);
    expect(bob.peer('alice-id')!.messages.single.text, 'hello bob');
    expect(bob.peer('alice-id')!.unread, 1);

    await bob.sendText('alice-id', 'hi alice');
    await eventually(() => alice.peer('bob-id')!.messages.length == 2);
    expect(alice.peer('bob-id')!.messages.last.mine, isFalse);
  });

  test('call: ring, answer, full-duplex audio, hang up', () async {
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.callPeer('bob-id');
    expect(alice.call!.state, CallState.outgoing);
    await eventually(() => bob.call?.state == CallState.incoming);

    await bob.accept();
    await eventually(() => alice.call?.state == CallState.active);
    expect(bob.call!.state, CallState.active);
    expect(aliceAudio.running && bobAudio.running, isTrue);

    final tone = Int16List.fromList(
      List.generate(320, (i) => (i * 97) % 20000 - 10000),
    );
    aliceAudio.inject(tone);
    await eventually(() => bobAudio.played.length >= 320);
    expect(bobAudio.played.sublist(0, 320), tone);

    bobAudio.inject(Int16List.fromList(List.filled(160, 42)));
    await eventually(() => aliceAudio.played.length >= 160);
    expect(aliceAudio.played.every((s) => s == 42), isTrue);

    // Muted microphone sends nothing.
    alice.toggleMute();
    final before = bobAudio.played.length;
    aliceAudio.inject(Int16List.fromList(List.filled(320, 7)));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(bobAudio.played.length, before);

    alice.hangup();
    expect(alice.call, isNull);
    await eventually(() => bob.call == null);
    expect(aliceAudio.running || bobAudio.running, isFalse);
  });

  test('declined call ends on both sides', () async {
    final events = <String>[];
    final sub = alice.events.listen((e) => events.add(e.message));
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.callPeer('bob-id');
    await eventually(() => bob.call?.state == CallState.incoming);
    bob.reject();
    await eventually(() => alice.call == null);
    expect(events.single, contains('declined'));
    await sub.cancel();
  });

  test('busy peer rejects a second caller', () async {
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await carol.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.callPeer('bob-id');
    await eventually(() => bob.call?.state == CallState.incoming);
    await bob.accept();

    final events = <String>[];
    final sub = carol.events.listen((e) => events.add(e.message));
    await carol.callPeer('bob-id');
    await eventually(() => carol.call == null);
    expect(events.single, contains('busy'));
    expect(bob.call!.peerId, 'alice-id');
    await sub.cancel();
  });

  test('switching peers ends the current call and calls the new one', () async {
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    await alice.addManualPeer('127.0.0.1', port: carol.listenPort!);
    carol.autoAnswer = true;

    await alice.callPeer('bob-id');
    await eventually(() => bob.call?.state == CallState.incoming);
    await bob.accept();
    await eventually(() => alice.call?.state == CallState.active);

    await alice.callPeer('carol-id'); // switch
    await eventually(() => bob.call == null);
    await eventually(() => alice.call?.state == CallState.active);
    expect(alice.call!.peerId, 'carol-id');
    expect(carol.call!.peerId, 'alice-id');
  });

  test('call ends when the peer disappears', () async {
    await alice.addManualPeer('127.0.0.1', port: bob.listenPort!);
    bob.autoAnswer = true;
    await alice.callPeer('bob-id');
    await eventually(() => alice.call?.state == CallState.active);
    await bob.shutdown();
    await eventually(() => alice.call == null);
    expect(alice.peer('bob-id')!.online, isFalse);
    // Re-create bob so tearDown can shut it down again harmlessly.
    bob = node('bob-id', 'Bob', bobAudio);
    await bob.start();
  });

  test('rmsLevel is 0 for silence and ~1 for full scale', () {
    expect(IntercomService.rmsLevel(Int16List(100)), 0);
    expect(
      IntercomService.rmsLevel(Int16List.fromList(List.filled(100, 32767))),
      closeTo(1, 0.01),
    );
  });
}
