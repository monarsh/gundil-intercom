import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intercom_core/intercom_core.dart';
import 'package:intercom_core/src/secure_channel.dart';
import 'package:test/test.dart';

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

IntercomCore node(String id, String name, {String password = ''}) =>
    IntercomCore(
      selfId: id,
      name: name,
      audio: FakeAudioEngine(),
      preferredPort: 0,
      enableDiscovery: false,
      rogerBeep: false,
      echoSuppression: false,
      password: password,
    );

/// Raw TCP client that reads frames, for looking at what's on the wire.
class RawClient {
  RawClient._(this.socket) {
    socket.listen(
      (d) {
        bytes.addAll(d);
        for (final f in _decoder.add(d)) {
          _frames.add(f);
        }
      },
      onDone: _frames.close,
      onError: (_) => _frames.close(),
    );
  }
  static Future<RawClient> connect(int port) async =>
      RawClient._(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket socket;
  final List<int> bytes = [];
  final FrameDecoder _decoder = FrameDecoder();
  final StreamController<Frame> _frames = StreamController<Frame>();
  late final StreamIterator<Frame> next = StreamIterator(_frames.stream);

  Future<Frame> read() async {
    if (!await next.moveNext().timeout(const Duration(seconds: 5))) {
      throw StateError('closed');
    }
    return next.current;
  }

  void send(Frame f) => socket.add(f.encode());
}

void main() {
  final cleanup = <IntercomCore>[];
  Future<IntercomCore> started(IntercomCore c) async {
    await c.start();
    cleanup.add(c);
    return c;
  }

  tearDown(() async {
    for (final c in cleanup) {
      await c.shutdown();
    }
    cleanup.clear();
  });

  test('the wire only carries the key exchange and ciphertext', () async {
    final alice = await started(node('alice-id', 'Alice-Secret-Name'));
    final raw = await RawClient.connect(alice.listenPort!);
    final key = await raw.read();
    expect(key.type, MessageType.key);
    expect(key.payload.length, 33);

    // Do the key exchange by hand and read Alice's HELLO.
    final mine = KeyPair.generate();
    raw.send(
      Frame(
        MessageType.key,
        Uint8List.fromList([keyExchangeVersion, ...mine.publicKey]),
      ),
    );
    final keys = SessionKeys.derive(
      mine,
      Uint8List.sublistView(key.payload, 1),
      networkSecret(''),
    );
    final opener = FrameCipher(keys.receiveKey);
    // First an encrypted ping: Alice says who she is only after we did.
    final first = await raw.read();
    expect(first.type, MessageType.sealed);
    expect(
      MessageType.fromCode(opener.open(first.payload).$1),
      MessageType.ping,
    );
    raw.send(
      Frame(
        MessageType.sealed,
        FrameCipher(keys.sendKey).seal(
          MessageType.hello.code,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'id': 'raw-id',
                'name': 'Raw',
                'port': 1,
                'v': protocolVersion,
              }),
            ),
          ),
        ),
      ),
    );
    final sealed = await raw.read();
    expect(sealed.type, MessageType.sealed);
    final (type, payload) = opener.open(sealed.payload);
    expect(MessageType.fromCode(type), MessageType.hello);
    expect(jsonDecode(utf8.decode(payload))['name'], 'Alice-Secret-Name');
    // ...but the name never appears in the raw bytes.
    expect(
      utf8.decode(raw.bytes, allowMalformed: true),
      isNot(contains('Alice-Secret-Name')),
    );
    raw.socket.destroy();
  });

  test('a call is encrypted end to end; both see the same code', () async {
    final alice = await started(node('alice-id', 'Alice', password: 'pw'));
    final bob = await started(node('bob-id', 'Bob', password: 'pw'));
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
    final code = alice.securityCode('bob-id');
    expect(code, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(bob.securityCode('alice-id'), code);
  });

  test('a different password is refused and shown', () async {
    final alice = await started(node('alice-id', 'Alice', password: 'one'));
    final bob = await started(node('bob-id', 'Bob', password: 'two'));
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isFalse,
    );
    expect(alice.savedPeers.single.peerId, isNull, reason: 'never identified');

    // Once they share the password, it connects.
    await bob.setPassword('one');
    expect(bob.password, 'one');
    alice.removeSavedPeer(alice.savedPeers.single.key);
    expect(
      await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!),
      isTrue,
    );
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => alice.inConversation && bob.inConversation);
  });

  test('wrong password flags a known peer; connect explains', () async {
    final alice = await started(node('alice-id', 'Alice'));
    final bob = await started(node('bob-id', 'Bob'));
    await alice.addSavedPeer(host: '127.0.0.1', port: bob.listenPort!);
    await alice.setPassword('changed');
    // The background retry finds out.
    await eventually(() => alice.peer('bob-id')!.wrongPassword);
    // Discovery still sees Bob on the network.
    alice.peer('bob-id')!.lastBeacon = DateTime.now();
    final events = <IntercomEvent>[];
    alice.events.listen(events.add);
    await alice.connect(const PeerTarget('bob-id'));
    await eventually(() => events.isNotEmpty);
    expect(
      events.map((e) => e.message),
      contains(contains('different intercom password')),
    );
    expect(alice.inConversation, isFalse);
  });

  test('an old unencrypted version shows as outdated and is refused', () async {
    final alice = await started(node('alice-id', 'Alice'));
    final raw = await RawClient.connect(alice.listenPort!);
    expect((await raw.read()).type, MessageType.key);
    // What 1.1.0 sends: plaintext HELLO, then OPEN.
    raw.send(
      Frame.json(MessageType.hello, {
        'id': 'old-id',
        'name': 'Old',
        'platform': 'linux',
        'port': 1,
        'v': 3,
      }),
    );
    await eventually(() => alice.peer('old-id') != null);
    expect(alice.peer('old-id')!.outdated, isTrue);
    raw.send(Frame.json(MessageType.open, {'sampleRate': 16000}));
    final reply = await raw.read();
    expect(reply.type, MessageType.reject);
    expect(reply.json['reason'], 'unsupported');
    expect(alice.conversation, isNull);
    raw.socket.destroy();
  });

  test('garbage instead of a key exchange is dropped', () async {
    final alice = await started(node('alice-id', 'Alice'));
    final raw = await RawClient.connect(alice.listenPort!);
    await raw.read();
    raw.send(Frame(MessageType.key, Uint8List(5)));
    // Alice hangs up on us: the stream ends without another frame.
    expect(
      await raw.next.moveNext().timeout(const Duration(seconds: 5)),
      isFalse,
    );
    raw.socket.destroy();
  });
}
