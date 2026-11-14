import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late IntercomCore alice, bob;
  IntercomCore node(String id, String name) => IntercomCore(
    selfId: id,
    name: name,
    audio: FakeAudioEngine(),
    preferredPort: 0,
    enableDiscovery: false,
    rogerBeep: false,
    echoSuppression: false,
  );

  PeerEntry entryOf(IntercomCore c, String id) =>
      c.entries.firstWhere((e) => e.peerId == id);

  setUp(() async {
    alice = node('alice-id', 'Alice');
    bob = node('bob-id', 'Bob');
    await Future.wait([alice.start(), bob.start()]);
  });

  tearDown(() async {
    await Future.wait([alice.shutdown(), bob.shutdown()]);
  });

  test('an online saved peer can be removed', () async {
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    expect(entryOf(alice, 'bob-id').online, isTrue);

    alice.removePeer(entryOf(alice, 'bob-id'));
    expect(alice.entries, isEmpty);
    expect(alice.savedPeers, isEmpty);
    await eventually(() => !(bob.peer('alice-id')?.connected ?? false));
  });

  test('a removed peer is not blocked: it can connect again', () async {
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    alice.removePeer(entryOf(alice, 'bob-id'));
    expect(alice.entries, isEmpty);

    expect(
      await bob.addSavedPeer(host: '127.0.0.1', port: alice.listenPort!),
      isTrue,
    );
    await eventually(() => alice.peer('bob-id')?.online ?? false);
    expect(entryOf(alice, 'bob-id').isSaved, isFalse);
  });

  test('an online peer that was not saved can be removed', () async {
    // Bob knows Alice; Alice only learns Bob from his connection.
    expect(
      await bob.addSavedPeer(host: '127.0.0.1', port: alice.listenPort!),
      isTrue,
    );
    await eventually(() => alice.peer('bob-id')?.online ?? false);
    final e = entryOf(alice, 'bob-id');
    expect(e.isSaved, isFalse);
    alice.removePeer(e);
    expect(alice.peer('bob-id'), isNull);
  });

  test('an offline peer can be removed', () async {
    expect(
      await bob.addSavedPeer(host: '127.0.0.1', port: alice.listenPort!),
      isTrue,
    );
    await eventually(() => alice.peer('bob-id')?.online ?? false);
    await bob.shutdown();
    await eventually(() => !entryOf(alice, 'bob-id').online);
    alice.removePeer(entryOf(alice, 'bob-id'));
    expect(alice.entries, isEmpty);
    bob = node('bob-id', 'Bob');
    await bob.start();
  });

  test('a removed peer can be added again by address', () async {
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    alice.removePeer(entryOf(alice, 'bob-id'));
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    expect(entryOf(alice, 'bob-id').online, isTrue);
  });

  test('removing a peer during a call hangs up with it', () async {
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    alice.removePeer(entryOf(alice, 'bob-id'));
    expect(alice.conversation, isNull);
    expect(alice.target, const EveryoneTarget());
    await eventually(() => bob.conversation == null);
  });
}
