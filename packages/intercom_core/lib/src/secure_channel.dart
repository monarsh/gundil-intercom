/// End-to-end encryption of the TCP link between two intercoms.
///
/// Every connection starts with a key exchange: both sides send a fresh
/// X25519 public key (a [MessageType.key] frame, the only plaintext frame).
/// From the shared secret, HKDF-SHA256 derives one ChaCha20-Poly1305 key per
/// direction plus a 6-digit security code. Every later frame (HELLO, calls,
/// audio, video) travels sealed inside a [MessageType.sealed] frame.
///
/// The optional intercom password is mixed into the key derivation (after
/// PBKDF2 hardening), so devices with a different password can't decrypt
/// each other's first frame and are refused. Without a password the link
/// is still encrypted against eavesdroppers; comparing the security code on
/// both screens rules out a man in the middle.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Version byte at the start of a KEY payload.
const int keyExchangeVersion = 1;

/// Bytes a sealed frame adds: the inner type byte and the 16-byte tag.
const int sealOverhead = 1 + 16;

final Random _random = Random.secure();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

// ------------------------------------------------------------------ X25519

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a24 = BigInt.from(121665);
final Uint8List _basePoint = Uint8List(32)..[0] = 9;

BigInt _decodeLE(Uint8List b) {
  var x = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    x = (x << 8) | BigInt.from(b[i]);
  }
  return x;
}

Uint8List _encodeLE(BigInt x) {
  final out = Uint8List(32);
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    out[i] = (x & mask).toInt();
    x = x >> 8;
  }
  return out;
}

/// X25519 scalar multiplication (RFC 7748): [scalar] times the point with
/// u-coordinate [u]. Both are 32 bytes, little-endian.
Uint8List x25519(Uint8List scalar, Uint8List u) {
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  final n = _decodeLE(k);
  final uu = Uint8List.fromList(u);
  uu[31] &= 127;
  final x1 = _decodeLE(uu) % _p;

  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = 0;
  for (var t = 254; t >= 0; t--) {
    final bit = ((n >> t) & BigInt.one).toInt();
    if ((swap ^ bit) == 1) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    swap = bit;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    final s = (da + cb) % _p;
    x3 = (s * s) % _p;
    final m = (da - cb) % _p;
    z3 = (x1 * m * m) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * (aa + _a24 * e)) % _p;
  }
  if (swap == 1) {
    (x2, x3) = (x3, x2);
    (z2, z3) = (z3, z2);
  }
  return _encodeLE((x2 * z2.modPow(_p - BigInt.two, _p)) % _p);
}

/// An ephemeral X25519 key pair (a new one for every connection).
class KeyPair {
  KeyPair._(this.privateKey, this.publicKey);

  factory KeyPair.generate() {
    final priv = randomBytes(32);
    return KeyPair._(priv, x25519(priv, _basePoint));
  }

  /// Tests only: a fixed private key.
  factory KeyPair.fromPrivate(Uint8List priv) =>
      KeyPair._(priv, x25519(priv, _basePoint));

  final Uint8List privateKey;
  final Uint8List publicKey;
}

// -------------------------------------------------------------------- KDFs

Uint8List _hmac(Uint8List key, List<Uint8List> parts) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  for (final p in parts) {
    mac.update(p, 0, p.length);
  }
  final out = Uint8List(32);
  mac.doFinal(out, 0);
  return out;
}

Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);

/// HKDF-SHA256 (RFC 5869).
Uint8List hkdf(Uint8List ikm, Uint8List salt, Uint8List info, int length) {
  final prk = _hmac(salt, [ikm]);
  final out = BytesBuilder(copy: false);
  var t = Uint8List(0);
  for (var i = 1; out.length < length; i++) {
    t = _hmac(prk, [
      t,
      info,
      Uint8List.fromList([i]),
    ]);
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// PBKDF2 iterations for the intercom password: slows down guessing it,
/// while staying a few seconds at most on an Orange Pi (pure Dart).
const int passwordIterations = 10000;

/// Turns the intercom password into the 32-byte network secret mixed into
/// every key exchange. An empty password gives a fixed public value (the
/// link is then encrypted, but any intercom can connect). Slow on purpose
/// (PBKDF2); compute once and keep the result.
Uint8List networkSecret(String password) {
  if (password.isEmpty) {
    return _sha256(utf8.encode('gundil-intercom/v4/no-password'));
  }
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(
      Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode('gundil-intercom/v4/password')),
        passwordIterations,
        32,
      ),
    );
  return kdf.process(Uint8List.fromList(utf8.encode(password)));
}

// ---------------------------------------------------------------- session

class KeyExchangeException implements Exception {
  KeyExchangeException(this.message);
  final String message;
  @override
  String toString() => 'KeyExchangeException: $message';
}

/// Keys for one connection, derived from both public keys.
class SessionKeys {
  SessionKeys._(this.sendKey, this.receiveKey, this.securityCode);

  /// Derives the session keys. Both sides get the same pair, swapped, and
  /// the same [securityCode] — unless someone sits in the middle.
  factory SessionKeys.derive(
    KeyPair mine,
    Uint8List theirPublic,
    Uint8List secret,
  ) {
    if (theirPublic.length != 32) {
      throw KeyExchangeException('bad public key');
    }
    final shared = x25519(mine.privateKey, theirPublic);
    if (shared.every((b) => b == 0)) {
      throw KeyExchangeException('weak public key');
    }
    final order = _compare(mine.publicKey, theirPublic);
    if (order == 0) throw KeyExchangeException('own key echoed');
    final low = order < 0 ? mine.publicKey : theirPublic;
    final high = order < 0 ? theirPublic : mine.publicKey;
    final info = BytesBuilder()
      ..add(utf8.encode('gundil-intercom/v4/session'))
      ..add(low)
      ..add(high);
    final okm = hkdf(shared, secret, info.takeBytes(), 32 + 32 + 4);
    final lowKey = Uint8List.sublistView(okm, 0, 32);
    final highKey = Uint8List.sublistView(okm, 32, 64);
    final c = ByteData.sublistView(okm, 64, 68).getUint32(0) % 1000000;
    final code = c.toString().padLeft(6, '0');
    return SessionKeys._(
      order < 0 ? lowKey : highKey,
      order < 0 ? highKey : lowKey,
      '${code.substring(0, 3)} ${code.substring(3)}',
    );
  }

  final Uint8List sendKey;
  final Uint8List receiveKey;

  /// "123 456": the same on both devices when nobody intercepts the link.
  final String securityCode;

  static int _compare(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}

/// Seals or opens the frames of one direction with ChaCha20-Poly1305. The
/// nonce is a frame counter: TCP keeps frames in order, so it never needs
/// to be sent, and a replayed, dropped or reordered frame fails to open.
class FrameCipher {
  FrameCipher(this._key);

  final Uint8List _key;
  int _counter = 0;

  Uint8List _nonce() {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, _counter++);
    return n;
  }

  /// Encrypts `[type][payload]`.
  Uint8List seal(int type, Uint8List payload) {
    final plain = Uint8List(1 + payload.length)
      ..[0] = type
      ..setRange(1, 1 + payload.length, payload);
    final c = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(true, AEADParameters(KeyParameter(_key), 128, _nonce(), _noAad));
    return _run(c, plain);
  }

  /// Decrypts a sealed payload into (type, payload). Throws
  /// [InvalidCipherTextException] when it was tampered with or sealed with
  /// another key (e.g. a different password).
  (int, Uint8List) open(Uint8List sealed) {
    if (sealed.length < sealOverhead) {
      throw InvalidCipherTextException('sealed frame too short');
    }
    final c = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(false, AEADParameters(KeyParameter(_key), 128, _nonce(), _noAad));
    final Uint8List plain;
    try {
      plain = _run(c, sealed);
    } on ArgumentError {
      // pointycastle reports a failed tag check as an ArgumentError.
      throw InvalidCipherTextException('frame failed authentication');
    }
    return (plain[0], Uint8List.sublistView(plain, 1));
  }

  static final Uint8List _noAad = Uint8List(0);

  static Uint8List _run(ChaCha20Poly1305 c, Uint8List input) {
    final out = Uint8List(c.getOutputSize(input.length));
    var n = c.processBytes(input, 0, input.length, out, 0);
    n += c.doFinal(out, n);
    return n == out.length ? out : Uint8List.sublistView(out, 0, n);
  }
}
