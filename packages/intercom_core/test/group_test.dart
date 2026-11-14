import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class Node {
  Node(this.id, this.name) {
    core = IntercomCore(
      selfId: id,
      name: name,
      audio: audio,
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
      echoSuppression: false,
      onGroupsChanged: (g) => stored = g,
    );
  }
  final String id, name;
  final audio = FakeAudioEngine();
  late final IntercomCore core;
  List<Group> stored = const [];

  /// Talks until [other] hears it.
  Future<void> heardBy(Node other, int value) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!other.audio.played.contains(value)) {
      if (DateTime.now().isAfter(end)) {
        fail('$name was not heard by ${other.name}');
      }
      audio.inject(Int16List.fromList(List.filled(1600, value)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  late Node a, b, c;

  setUp(() async {
    a = Node('a-id', 'Alice');
    b = Node('b-id', 'Bob');
    c = Node('c-id', 'Carol');
    await Future.wait([a.core.start(), b.core.start(), c.core.start()]);
    // Alice knows both; Bob and Carol don't know each other.
    for (final n in [b, c]) {
      expect(
        await a.core.addSavedPeer(host: '127.0.0.1', port: n.core.listenPort!),
        isTrue,
      );
      await eventually(() => n.core.peer('a-id')?.connected ?? false);
    }
  });

  tearDown(() async {
    await Future.wait([
      a.core.shutdown(),
      b.core.shutdown(),
      c.core.shutdown(),
    ]);
  });

  test('a new group reaches its members, who can change it', () async {
    final g = a.core.createGroup('Family', ['b-id', 'c-id']);
    expect(a.stored.single.id, g.id);
    await eventually(() => b.core.group(g.id) != null);
    await eventually(() => c.core.group(g.id) != null);
    expect(b.core.group(g.id)!.name, 'Family');
    expect(b.core.group(g.id)!.members.keys, containsAll(['a-id', 'c-id']));
    expect(b.stored, hasLength(1)); // Persisted.

    // Any member can rename it.
    b.core.updateGroup(g.id, name: 'Home');
    await eventually(() => a.core.group(g.id)?.name == 'Home');
    // Carol hears it from Alice (she doesn't know Bob).
    await eventually(() => c.core.group(g.id)?.name == 'Home');
  });

  test('leaving and removing members', () async {
    final g = a.core.createGroup('Team', ['b-id', 'c-id']);
    await eventually(() => c.core.group(g.id) != null);
    c.core.leaveGroup(g.id);
    expect(c.core.group(g.id), isNull);
    await eventually(
      () => !(a.core.group(g.id)?.members.containsKey('c-id') ?? true),
    );

    a.core.updateGroup(g.id, memberIds: ['c-id']); // Carol in, Bob out.
    await eventually(() => c.core.group(g.id) != null);
    await eventually(() => b.core.group(g.id) == null);
  });

  test('a member that was offline gets the group when it connects', () async {
    await c.core.shutdown();
    final g = a.core.createGroup('Late', ['b-id', 'c-id']);
    await eventually(() => b.core.group(g.id) != null);
    expect(c.core.group(g.id), isNull);

    c = Node('c-id', 'Carol');
    await c.core.start();
    await a.core.updateSavedPeer(
      a.core.savedPeers.firstWhere((s) => s.peerId == 'c-id').key,
      label: '',
      host: '127.0.0.1',
      port: c.core.listenPort!,
    );
    await eventually(() => c.core.group(g.id)?.name == 'Late');
  });

  test('in a group call everyone hears everyone', () async {
    final g = a.core.createGroup('Crew', ['b-id', 'c-id']);
    await eventually(() => c.core.group(g.id) != null);
    await a.core.connect(GroupTarget(g.id));
    await eventually(
      () =>
          a.core.conversation?.connected.length == 2 &&
          b.core.inConversation &&
          c.core.inConversation,
    );
    // Bob and Carol connect to each other on their own.
    await eventually(
      () =>
          b.core.memberState('c-id') == MemberState.connected &&
          c.core.memberState('b-id') == MemberState.connected,
    );
    expect(b.core.participants, containsAll(['a-id', 'c-id']));
    await b.heardBy(c, 21);
    await c.heardBy(b, 31);
    await a.heardBy(b, 11);
    await a.heardBy(c, 12);

    // Bob leaves: the others carry on.
    b.core.hangUp();
    await eventually(() => a.core.participants.length == 1);
    expect(c.core.participants, ['a-id']);
    expect(a.core.inConversation && c.core.inConversation, isTrue);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('members that cannot reach each other hear each other through '
      'another member', () async {
    b.core.debugUnreachable.add('c-id');
    c.core.debugUnreachable.add('b-id');
    final g = a.core.createGroup('Split', ['b-id', 'c-id']);
    await eventually(() => c.core.group(g.id) != null);
    await a.core.connect(GroupTarget(g.id));
    await eventually(() => b.core.inConversation && c.core.inConversation);
    await eventually(() => b.core.participants.contains('c-id'));
    await b.heardBy(c, 41);
    await c.heardBy(b, 51);
    expect(b.core.memberState('c-id'), isNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('calling a group someone is already talking in joins it', () async {
    final g = a.core.createGroup('Join', ['b-id', 'c-id']);
    await eventually(() => c.core.group(g.id) != null);
    // Only Alice and Bob talk at first: Carol declines... by being busy.
    c.core.autoAnswer = false;
    await a.core.connect(GroupTarget(g.id));
    await eventually(() => b.core.inConversation && c.core.ringing);
    c.core.decline();
    await eventually(() => c.core.conversation == null);
    // Later Carol calls the group herself and joins the running call.
    await c.core.connect(GroupTarget(g.id));
    await eventually(
      () =>
          c.core.memberState('a-id') == MemberState.connected &&
          c.core.memberState('b-id') == MemberState.connected,
    );
    await c.heardBy(b, 61);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a non-member cannot call the group', () async {
    final g = a.core.createGroup('Pair', ['b-id']);
    await eventually(() => b.core.group(g.id) != null);
    expect(c.core.group(g.id), isNull);
    await a.core.connect(GroupTarget(g.id));
    await eventually(() => b.core.inConversation);
    expect(c.core.conversation, isNull);
  });
}
