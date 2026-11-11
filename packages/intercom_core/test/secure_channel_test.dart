import 'dart:typed_data';

import 'package:intercom_core/src/secure_channel.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  test('X25519 matches RFC 7748 test vectors', () {
    // Section 5.2, first vector.
    expect(
      x25519(
        hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
        hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c'),
      ),
      hex('c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'),
    );
    // Section 6.1: Alice and Bob agree.
    final alice = KeyPair.fromPrivate(
      hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
    );
    final bob = KeyPair.fromPrivate(
      hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'),
    );
    expect(
      alice.publicKey,
      hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'),
    );
    final shared = hex(
      '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
    );
    expect(x25519(alice.privateKey, bob.publicKey), shared);
    expect(x25519(bob.privateKey, alice.publicKey), shared);
  });

  test('HKDF matches RFC 5869 test case 1', () {
    expect(
      hkdf(
        hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        hex('000102030405060708090a0b0c'),
        hex('f0f1f2f3f4f5f6f7f8f9'),
        42,
      ),
      hex(
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      ),
    );
  });

  group('session', () {
    final secret = networkSecret('');
    late KeyPair a, b;
    setUp(() {
      a = KeyPair.generate();
      b = KeyPair.generate();
    });

    test('both sides get matching keys and the same code', () {
      final ka = SessionKeys.derive(a, b.publicKey, secret);
      final kb = SessionKeys.derive(b, a.publicKey, secret);
      expect(ka.sendKey, kb.receiveKey);
      expect(ka.receiveKey, kb.sendKey);
      expect(ka.sendKey, isNot(ka.receiveKey));
      expect(ka.securityCode, kb.securityCode);
      expect(ka.securityCode, matches(RegExp(r'^\d{3} \d{3}$')));
    });

    test('frames round-trip in order; tampering and replay fail', () {
      final ka = SessionKeys.derive(a, b.publicKey, secret);
      final kb = SessionKeys.derive(b, a.publicKey, secret);
      final send = FrameCipher(ka.sendKey);
      final recv = FrameCipher(kb.receiveKey);
      final s1 = send.seal(4, Uint8List.fromList([1, 2, 3]));
      final s2 = send.seal(5, Uint8List(0));
      expect(s1.length, 3 + sealOverhead);
      final (t1, p1) = recv.open(s1);
      expect(t1, 4);
      expect(p1, [1, 2, 3]);
      final (t2, p2) = recv.open(s2);
      expect((t2, p2.length), (5, 0));
      // Replaying s1 fails (the counter moved on).
      expect(() => recv.open(s1), throwsA(isA<InvalidCipherTextException>()));
      final r2 = FrameCipher(kb.receiveKey);
      final bad = Uint8List.fromList(s1)..[0] ^= 1;
      expect(() => r2.open(bad), throwsA(isA<InvalidCipherTextException>()));
    });

    test('a different password cannot open the frames', () {
      final ka = SessionKeys.derive(a, b.publicKey, networkSecret('gate-123'));
      final kb = SessionKeys.derive(b, a.publicKey, networkSecret('gate-124'));
      final sealed = FrameCipher(ka.sendKey).seal(1, Uint8List(10));
      expect(
        () => FrameCipher(kb.receiveKey).open(sealed),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });

    test('rejects own key and the all-zero point', () {
      expect(
        () => SessionKeys.derive(a, a.publicKey, secret),
        throwsA(isA<KeyExchangeException>()),
      );
      expect(
        () => SessionKeys.derive(a, Uint8List(32), secret),
        throwsA(isA<KeyExchangeException>()),
      );
    });
  });

  test('password secret is deterministic and differs per password', () {
    expect(networkSecret('abc'), networkSecret('abc'));
    expect(networkSecret('abc'), isNot(networkSecret('abd')));
    expect(networkSecret(''), isNot(networkSecret('abc')));
  });
}
