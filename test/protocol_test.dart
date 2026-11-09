import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/discovery.dart';
import 'package:p2p_intercom/src/protocol.dart';

void main() {
  group('FrameDecoder', () {
    test('round-trips frames delivered byte by byte', () {
      final frames = [
        Frame.json(MessageType.hello, {'id': 'abc', 'name': 'Ünïcode ☎'}),
        Frame.empty(MessageType.ping),
        Frame(
          MessageType.audio,
          Uint8List.fromList(List.generate(640, (i) => i % 256)),
        ),
      ];
      final bytes = frames.expand((f) => f.encode()).toList();
      final decoder = FrameDecoder();
      final out = <Frame>[];
      for (final b in bytes) {
        out.addAll(decoder.add([b]));
      }
      expect(out.map((f) => f.type), [
        MessageType.hello,
        MessageType.ping,
        MessageType.audio,
      ]);
      expect(out[0].json['name'], 'Ünïcode ☎');
      expect(out[2].payload, frames[2].payload);
    });

    test('decodes many frames from one chunk', () {
      final bytes = <int>[];
      for (var i = 0; i < 50; i++) {
        bytes.addAll(Frame.json(MessageType.talkStart, {'n': 'm$i'}).encode());
      }
      final out = FrameDecoder().add(bytes);
      expect(out.length, 50);
      expect(out.last.json['n'], 'm49');
    });

    test('skips unknown frame types', () {
      final unknown = Frame(MessageType.ping, Uint8List(3)).encode()
        ..[0] = 0x7f;
      final out = FrameDecoder().add([
        ...unknown,
        ...Frame.empty(MessageType.pong).encode(),
      ]);
      expect(out.single.type, MessageType.pong);
    });

    test('rejects oversized frames', () {
      final header = Uint8List(5)..[0] = MessageType.audio.code;
      ByteData.sublistView(header).setUint32(1, maxFramePayload + 1);
      expect(
        () => FrameDecoder().add(header),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  test('PCM conversion is lossless little-endian', () {
    final pcm = Int16List.fromList([0, 1, -1, 32767, -32768, 1234]);
    final bytes = pcmToBytes(pcm);
    expect(bytes.sublist(0, 4), [0, 0, 1, 0]);
    expect(bytesToPcm(bytes), pcm);
  });

  group('Discovery.parseBeacon', () {
    final from = InternetAddress('192.168.1.5');
    List<int> b(String s) => s.codeUnits;

    test('accepts valid beacon', () {
      final beacon = Discovery.parseBeacon(
        b(
          '{"app":"p2p-intercom","v":1,"id":"x","name":"Kitchen","platform":"android","port":47801}',
        ),
        from,
        'me',
      )!;
      expect(beacon.name, 'Kitchen');
      expect(beacon.tcpPort, 47801);
      expect(beacon.address, from);
      expect(beacon.leaving, isFalse);
    });

    test('ignores own, foreign and garbage packets', () {
      expect(
        Discovery.parseBeacon(
          b('{"app":"p2p-intercom","id":"me","port":1}'),
          from,
          'me',
        ),
        isNull,
      );
      expect(
        Discovery.parseBeacon(
          b('{"app":"other","id":"x","port":1}'),
          from,
          'me',
        ),
        isNull,
      );
      expect(Discovery.parseBeacon(b('not json'), from, 'me'), isNull);
      expect(
        Discovery.parseBeacon(
          b('{"app":"p2p-intercom","id":"x","port":99999}'),
          from,
          'me',
        ),
        isNull,
      );
    });
  });
}
