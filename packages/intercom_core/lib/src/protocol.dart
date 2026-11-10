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
/// Control messages carry UTF-8 JSON payloads; [MessageType.audio] carries raw
/// signed 16-bit little-endian mono PCM at the sample rate announced in the
/// [MessageType.open] that started the conversation.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Protocol version, sent in [MessageType.hello] and discovery beacons.
const int protocolVersion = 3;

/// Oldest peer protocol we can hold a two-way conversation with.
const int minConversationVersion = 3;

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
  pong(0x09);

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
