import 'dart:io';

import 'package:intercom_core/intercom_core.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

IntercomCore node(String id, String name) => IntercomCore(
  selfId: id,
  name: name,
  audio: FakeAudioEngine(),
  preferredPort: 0,
  enableDiscovery: false,
  rogerBeep: false,
  echoSuppression: false,
);

void main() {
  late IntercomCore alice, bob;

  setUp(() async {
    alice = node('alice-id', 'Alice');
    bob = node('bob-id', 'Bob');
    await Future.wait([alice.start(), bob.start()]);
  });

  tearDown(() async {
    await Future.wait([alice.shutdown(), bob.shutdown()]);
  });

  test(
    'the alternate address is used when the primary is unreachable',
    () async {
      final sw = Stopwatch()..start();
      // 192.0.2.1 (TEST-NET-1) never answers; the alternate does.
      expect(
        await alice.addSavedPeer(
          host: '192.0.2.1',
          port: bob.listenPort!,
          altHost: '127.0.0.1',
        ),
        isTrue,
      );
      // Without waiting for the primary to time out (3 s).
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      final e = alice.entries.single;
      expect(e.peerId, 'bob-id');
      expect(e.saved!.host, '192.0.2.1'); // The primary is kept as entered.
      expect(e.altHost, '127.0.0.1');
    },
  );

  test('an alternate can be added to a saved peer later', () async {
    expect(
      await alice.addSavedPeer(host: '192.0.2.1', port: bob.listenPort!),
      isFalse,
    );
    final key = alice.savedPeers.single.key;
    expect(await alice.updateSavedPeer(key, altHost: '127.0.0.1'), isTrue);
    expect(alice.peer('bob-id')?.online, isTrue);
  });

  test('a discovered peer can be kept with an alternate address', () async {
    expect(
      await bob.addSavedPeer(host: '127.0.0.1', port: alice.listenPort!),
      isTrue,
    );
    await eventually(() => alice.peer('bob-id')?.online ?? false);
    final s = alice.saveLivePeer('bob-id', altHost: '10.9.8.7');
    expect(s.altHost, '10.9.8.7');
    expect(s.hosts, ['127.0.0.1', '10.9.8.7']);
  });

  test('the alternate must differ from the primary', () async {
    expect(
      () => alice.addSavedPeer(host: '1.2.3.4', altHost: '1.2.3.4'),
      throwsArgumentError,
    );
  });

  test('saved with the settings', () {
    final s = SavedPeer(
      key: 'k',
      host: '192.168.1.5',
      port: 47801,
      altHost: '100.64.0.7',
    );
    final back = SavedPeer.fromJson(s.toJson())!;
    expect(back.altHost, '100.64.0.7');
    expect(back.hosts, ['192.168.1.5', '100.64.0.7']);
    // Older settings without one.
    expect(
      SavedPeer.fromJson({'key': 'k', 'host': 'h', 'port': 1})!.altHost,
      '',
    );
  });

  test('peers learn each other\'s other addresses from HELLO', () async {
    final mine = {
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        for (final a in i.addresses) a.address,
    };
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    await eventually(() => alice.peer('bob-id') != null);
    final announced = alice
        .peer('bob-id')!
        .announced
        .map((a) => a.address)
        .toSet();
    expect(announced, mine);
  });
}
