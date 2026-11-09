import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// A single TCP link to a remote peer, speaking the framed [protocol].
class PeerConnection {
  PeerConnection(this.socket, {required this.outgoing}) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _close(e),
      onDone: () => _close(null),
      cancelOnError: true,
    );
  }

  /// Connects to [host]:[port].
  static Future<PeerConnection> connect(
    InternetAddress host,
    int port, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return PeerConnection(socket, outgoing: true);
  }

  final Socket socket;

  /// Whether we initiated this connection.
  final bool outgoing;

  /// Remote peer id, known once its HELLO arrives.
  String? remoteId;

  final FrameDecoder _decoder = FrameDecoder();
  late final StreamSubscription<List<int>> _sub;
  final StreamController<Frame> _frames = StreamController<Frame>();
  final Completer<void> _closed = Completer<void>();
  bool _isClosed = false;

  Stream<Frame> get frames => _frames.stream;
  Future<void> get done => _closed.future;
  bool get isClosed => _isClosed;

  InternetAddress get remoteAddress => socket.remoteAddress;
  int get remotePort => socket.remotePort;

  void send(Frame frame) {
    if (_isClosed) return;
    try {
      socket.add(frame.encode());
    } catch (e) {
      _close(e);
    }
  }

  void _onData(List<int> data) {
    try {
      for (final f in _decoder.add(data)) {
        _frames.add(f);
      }
    } on ProtocolException catch (e) {
      _close(e);
    }
  }

  Future<void> close() async {
    if (_isClosed) return;
    try {
      await socket.flush().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    _close(null);
  }

  void _close(Object? error) {
    if (_isClosed) return;
    _isClosed = true;
    _sub.cancel();
    socket.destroy();
    _frames.close();
    _closed.complete();
  }
}
