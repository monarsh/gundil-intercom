import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Reads a key from a Linux input device (`/dev/input/eventN`), e.g. a USB
/// keyboard, foot pedal or USB "PTT button" (most present as keyboards).
/// Emits true on key down and false on key up.
class InputKey {
  InputKey._(this._sub, this._controller);

  final StreamSubscription<List<int>> _sub;
  final StreamController<bool> _controller;

  Stream<bool> get changes => _controller.stream;

  static const int _evKey = 1;

  /// `struct input_event` is 16 bytes on 32-bit ARM, 24 on 64-bit.
  static int get eventSize => sizeOf<IntPtr>() == 4 ? 16 : 24;

  static InputKey open(String device, int keyCode) {
    final controller = StreamController<bool>.broadcast();
    final size = eventSize;
    final pending = BytesBuilder(copy: false);
    final sub = File(device).openRead().listen((chunk) {
      pending.add(chunk);
      var bytes = pending.takeBytes();
      var off = 0;
      while (bytes.length - off >= size) {
        final e = parseEvent(bytes, off, size);
        off += size;
        if (e == null || e.code != keyCode) continue;
        if (e.value == 1) controller.add(true); // press
        if (e.value == 0) controller.add(false); // release (2 = repeat)
      }
      if (off < bytes.length) pending.add(bytes.sublist(off));
    }, onError: (Object e) => controller.addError(e));
    return InputKey._(sub, controller);
  }

  /// Returns (code, value) of a key event at [offset], or null otherwise.
  static ({int code, int value})? parseEvent(
    Uint8List bytes,
    int offset,
    int size,
  ) {
    final d = ByteData.sublistView(bytes, offset, offset + size);
    final timeLen = size - 8; // two longs: 8 (32-bit) or 16 (64-bit)
    final type = d.getUint16(timeLen, Endian.little);
    if (type != _evKey) return null;
    return (
      code: d.getUint16(timeLen + 2, Endian.little),
      value: d.getInt32(timeLen + 4, Endian.little),
    );
  }

  Future<void> close() async {
    await _sub.cancel();
    await _controller.close();
  }
}
