import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/video_call.dart';

/// The video area of a call: every peer whose camera is on, plus a small
/// self-view while our own camera is on. With no remote video, the
/// self-view fills the area.
class VideoStage extends StatelessWidget {
  const VideoStage({super.key, required this.service, required this.video});

  final IntercomService service;
  final VideoCall video;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([service, video]),
      builder: (context, _) {
        final peers = service.videoPeers;
        final self = video.on ? _SelfView(video: video) : null;
        if (peers.isEmpty) {
          return self == null
              ? const SizedBox.shrink()
              : _Tile(name: 'You', child: self);
        }
        return LayoutBuilder(
          builder: (context, box) {
            final pipW = (box.maxWidth * 0.28).clamp(90.0, 220.0);
            return Stack(
              children: [
                Positioned.fill(child: _grid(peers, box)),
                if (self != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    width: pipW,
                    height: pipW * 4 / 3,
                    child: _Tile(name: 'You', small: true, child: self),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _grid(List<String> peers, BoxConstraints box) {
    final tiles = [
      for (final id in peers)
        _Tile(
          name: service.displayName(id),
          speaking: service.isSpeaking(id),
          child: _RemoteView(service: service, peerId: id),
        ),
    ];
    if (tiles.length == 1) return tiles.single;
    // Side by side on wide screens, stacked on tall ones.
    final columns = tiles.length <= 2
        ? (box.maxWidth > box.maxHeight ? 2 : 1)
        : (tiles.length <= 4 ? 2 : 3);
    final rows = (tiles.length / columns).ceil();
    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < columns; c++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: r * columns + c < tiles.length
                          ? tiles[r * columns + c]
                          : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Rounded black frame with a name label; a green border while speaking.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.name,
    required this.child,
    this.speaking = false,
    this.small = false,
  });

  final String name;
  final Widget child;
  final bool speaking;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(small ? 10 : 14);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: radius,
        border: Border.all(
          color: speaking ? Colors.green : Colors.white24,
          width: speaking ? 3 : 1,
        ),
        boxShadow: small
            ? const [BoxShadow(color: Colors.black54, blurRadius: 8)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (speaking) ...[
                      const Icon(
                        Icons.graphic_eq,
                        size: 14,
                        color: Colors.green,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      name,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: small ? 11 : 13,
                        fontWeight: speaking ? FontWeight.bold : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A peer's camera, repainted on every new picture.
class _RemoteView extends StatelessWidget {
  const _RemoteView({required this.service, required this.peerId});

  final IntercomService service;
  final String peerId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: service.videoTick,
      builder: (context, _, _) {
        final f = service.remoteVideo(peerId);
        if (f == null) return const SizedBox.shrink();
        return _Picture(jpeg: f.jpeg, rotation: f.rotation);
      },
    );
  }
}

/// Our own camera (mirrored for a front camera, like a mirror).
class _SelfView extends StatelessWidget {
  const _SelfView({required this.video});

  final VideoCall video;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: video.previewTick,
      builder: (context, _, _) {
        final jpeg = video.preview;
        if (jpeg == null) {
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return _Picture(
          jpeg: jpeg,
          rotation: video.previewRotation,
          mirror: video.mirror,
        );
      },
    );
  }
}

/// Shows a JPEG picture stream. Decodes straight to a [ui.Image] (no image
/// cache churn at 15 fps) and skips pictures that arrive while the previous
/// one is still decoding.
class _Picture extends StatefulWidget {
  const _Picture({required this.jpeg, this.rotation = 0, this.mirror = false});

  final Uint8List jpeg;
  final int rotation;
  final bool mirror;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  ui.Image? _image;
  bool _decoding = false;
  Uint8List? _pending;

  @override
  void initState() {
    super.initState();
    _decode(widget.jpeg);
  }

  @override
  void didUpdateWidget(_Picture old) {
    super.didUpdateWidget(old);
    if (!identical(old.jpeg, widget.jpeg)) _decode(widget.jpeg);
  }

  Future<void> _decode(Uint8List jpeg) async {
    if (_decoding) {
      _pending = jpeg; // Only the newest waiting picture matters.
      return;
    }
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() => _image = frame.image);
      old?.dispose();
    } catch (_) {
      // A corrupt picture: keep the previous one.
    } finally {
      _decoding = false;
    }
    final next = _pending;
    _pending = null;
    if (next != null && mounted) _decode(next);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    Widget img = RawImage(
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
    if (widget.rotation != 0) {
      img = RotatedBox(quarterTurns: widget.rotation, child: img);
    }
    if (widget.mirror) img = Transform.flip(flipX: true, child: img);
    return img;
  }
}
