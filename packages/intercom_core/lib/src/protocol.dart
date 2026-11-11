/// Wire protocol spoken between intercom peers over TCP.
///
/// Every message is a frame:
///
/// ```
/// +--------+----------------------+-----------------+
/// | type   | payload length (BE)  | payload         |
/// | 1 byte | 4 bytes, uint32      | `length` bytes  |
/// +--------+----------------------+-----------------+
/// ```
///
/// After the key exchange every frame travels encrypted inside a
/// [MessageType.sealed] frame. Control messages carry UTF-8 JSON payloads; [MessageType.audio] carries raw
/// signed 16-bit little-endian mono PCM at the sample rate announced in the
/// [MessageType.open] that started the conversation. [MessageType.video]
/// carries one JPEG camera picture (see [VideoFrame]).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Protocol version, sent in [MessageType.hello] and discovery beacons.
/// 4 = encrypted links (see `secure_channel.dart`).
const int protocolVersion = 4;

/// Oldest peer protocol we can hold a two-way conversation with.
/// Older versions don't encrypt and can't connect.
const int minConversationVersion = 4;

/// Default TCP port each peer listens on.
const int defaultTcpPort = 47801;

/// UDP port used for LAN discovery beacons.
const int discoveryPort = 47800;

/// Default audio sample rate (wideband voice).
const int defaultSampleRate = 16000;

/// Largest frame accepted from the network. Protects against garbage input.
const int maxFramePayload = 256 * 1024;

const int frameHeaderLength = 5;

enum MessageType {
  /// `{"id","name","platform","port","v"}` - sent by both ends on connect.
  hello(0x01),

  /// Open a two-way audio line: `{"sampleRate": 16000, "group": bool}`.
  open(0x02),

  /// Leave / hang up the line.
  close(0x03),

  /// Raw PCM16LE mono microphone samples (both directions while connected).
  audio(0x04),

  /// The line was accepted (sent automatically when auto-answer is on).
  accept(0x05),

  /// The line was refused: `{"reason": "busy" | "declined" | "timeout"}`.
  reject(0x06),
  ping(0x08),
  pong(0x09),

  /// One camera picture: `[rotation:1][JPEG]`, where `rotation` is the number
  /// of clockwise quarter turns needed to show it upright. A payload of just
  /// the rotation byte means "camera turned off". Only sent to peers whose
  /// HELLO says `"video": true`; older peers skip unknown frame types anyway.
  video(0x0A),

  /// Acknowledges one [video] frame. The sender keeps only a couple of
  /// pictures in flight per peer, so video never piles up in the TCP buffer
  /// and delays the audio.
  videoAck(0x0B),

  /// Key exchange, the first frame each side sends and the only plaintext
  /// one: `[version:1][X25519 public key:32]`.
  key(0x10),

  /// Every other frame, encrypted: ChaCha20-Poly1305 of `[type:1][payload]`
  /// with the 16-byte tag appended (see `secure_channel.dart`).
  sealed(0x11);

  const MessageType(this.code);
  final int code;

  static MessageType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

class Frame {
  Frame(this.type, this.payload);

  Frame.json(MessageType type, Map<String, Object?> body)
    : this(type, Uint8List.fromList(utf8.encode(jsonEncode(body))));

  Frame.empty(MessageType type) : this(type, Uint8List(0));

  final MessageType type;
  final Uint8List payload;

  Map<String, Object?> get json {
    if (payload.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(payload));
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  Uint8List encode() {
    final out = Uint8List(frameHeaderLength + payload.length);
    out[0] = type.code;
    ByteData.sublistView(out).setUint32(1, payload.length, Endian.big);
    out.setRange(frameHeaderLength, out.length, payload);
    return out;
  }

  @override
  String toString() => 'Frame(${type.name}, ${payload.length} bytes)';
}

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

/// Incremental decoder turning an arbitrary chunked TCP byte stream into
/// [Frame]s.
class FrameDecoder {
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Uint8List _buf = Uint8List(0);
  int _offset = 0;

  /// Feeds [chunk] and returns every complete frame now available.
  /// Throws [ProtocolException] on malformed input.
  List<Frame> add(List<int> chunk) {
    if (_offset < _buf.length) {
      _pending.add(Uint8List.sublistView(_buf, _offset));
    }
    _pending.add(chunk);
    _buf = _pending.takeBytes();
    _offset = 0;

    final frames = <Frame>[];
    final view = ByteData.sublistView(_buf);
    while (_buf.length - _offset >= frameHeaderLength) {
      final code = _buf[_offset];
      final length = view.getUint32(_offset + 1, Endian.big);
      if (length > maxFramePayload) {
        throw ProtocolException('frame too large: $length bytes');
      }
      if (_buf.length - _offset - frameHeaderLength < length) break;
      final start = _offset + frameHeaderLength;
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_buf, start, start + length),
      );
      _offset = start + length;
      final type = MessageType.fromCode(code);
      // Unknown types are skipped for forward compatibility.
      if (type != null) frames.add(Frame(type, payload));
    }
    return frames;
  }
}

/// Converts PCM samples to the little-endian wire representation.
Uint8List pcmToBytes(Int16List samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

/// Converts little-endian wire bytes back to PCM samples.
Int16List bytesToPcm(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  final out = Int16List(count);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little);
  }
  return out;
}

/// One received camera picture.
class VideoFrame {
  VideoFrame(this.jpeg, {this.rotation = 0, DateTime? receivedAt})
    : receivedAt = receivedAt ?? DateTime.now();

  /// JPEG-encoded picture.
  final Uint8List jpeg;

  /// Clockwise quarter turns (0..3) needed to show the picture upright.
  final int rotation;

  final DateTime receivedAt;

  /// Wire payload of a [MessageType.video] frame for [jpeg].
  static Uint8List encode(Uint8List jpeg, {int rotation = 0}) {
    final out = Uint8List(1 + jpeg.length);
    out[0] = rotation & 3;
    out.setRange(1, out.length, jpeg);
    return out;
  }

  /// Wire payload meaning "my camera is off".
  static Uint8List encodeOff() => Uint8List(1);

  /// Parses a [MessageType.video] payload; null means the camera is off.
  static VideoFrame? decode(Uint8List payload) {
    if (payload.length < 2) return null;
    return VideoFrame(
      Uint8List.sublistView(payload, 1),
      rotation: payload[0] & 3,
    );
  }
}
