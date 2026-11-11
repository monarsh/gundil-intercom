import 'dart:io';

import 'package:flutter/material.dart';

import '../src/audio_routes.dart';
import '../src/intercom_service.dart';
import '../src/video_call.dart';

/// Main control area: connect / hang up the two-way audio line, accept or
/// decline when someone rings, mute and speaker controls.
class IntercomPanel extends StatelessWidget {
  const IntercomPanel({
    super.key,
    required this.service,
    this.video,
    this.onMessage,
    this.compact = false,
    this.showParticipants = true,
  });

  final IntercomService service;

  /// The local camera (camera buttons during a call), if available.
  final VideoCall? video;

  /// Shows a short message (e.g. "Camera permission denied").
  final void Function(String message, {bool error})? onMessage;

  /// Show the participant cards (hidden while the video takes the screen;
  /// the video tiles show who's speaking instead).
  final bool showParticipants;

  /// Smaller layout for phones (under the peer list).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final conv = service.conversation;
        final Widget body;
        if (conv != null && service.ringing) {
          body = _ringing(context, conv);
        } else if (conv != null) {
          body = _active(context, conv);
        } else {
          body = _idle(context);
        }
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: compact ? 12 : 24,
          ),
          child: body,
        );
      },
    );
  }

  double get _size => !showParticipants
      ? (compact ? 76 : 96) // Video on: leave the room to the pictures.
      : (compact ? 132 : 200);

  // ------------------------------------------------------------------ idle

  Widget _idle(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final target = service.target;
    final targetName = service.targetName(target);
    final online = switch (target) {
      EveryoneTarget() => service.onlinePeers.isNotEmpty,
      PeerTarget(:final peerId) => service.peer(peerId)?.online ?? false,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundButton(
          size: _size,
          color: online
              ? Colors.green.shade600
              : Theme.of(context).disabledColor,
          icon: target is EveryoneTarget ? Icons.campaign : Icons.call,
          label: 'CONNECT',
          onTap: online ? service.connect : null,
        ),
        SizedBox(height: compact ? 10 : 20),
        Text(
          online ? 'Talk with $targetName' : '$targetName is offline',
          textAlign: TextAlign.center,
          style: compact ? text.titleMedium : text.titleLarge,
        ),
        if (!compact) ...[
          const SizedBox(height: 6),
          Text(
            'Two-way audio: both sides talk and listen until one hangs up.',
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ],
      ],
    );
  }

  // --------------------------------------------------------------- ringing

  Widget _ringing(BuildContext context, Conversation conv) {
    final text = Theme.of(context).textTheme;
    final who = conv.ringing.map(service.displayName).join(', ');
    final small = _size * 0.55;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.ring_volume, size: compact ? 36 : 56, color: Colors.green),
        const SizedBox(height: 8),
        Text(
          '$who wants to talk${conv.group ? ' (everyone)' : ''}',
          textAlign: TextAlign.center,
          style: compact ? text.titleMedium : text.titleLarge,
        ),
        SizedBox(height: compact ? 12 : 24),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoundButton(
              size: small,
              color: Colors.red,
              icon: Icons.call_end,
              label: 'DECLINE',
              onTap: service.decline,
            ),
            SizedBox(width: compact ? 32 : 56),
            _RoundButton(
              size: small,
              color: Colors.green.shade600,
              icon: Icons.call,
              label: 'ACCEPT',
              onTap: service.accept,
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- active

  Widget _active(BuildContext context, Conversation conv) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final connected = conv.connected.toList();
    final calling = conv.calling.toList();

    final String status;
    String? timer;
    final speakers = service.speakers;
    if (connected.isEmpty) {
      status = conv.group
          ? 'Connecting to everyone…'
          : 'Connecting to ${calling.map(service.displayName).join(', ')}…';
    } else {
      final since = conv.connectedAt ?? DateTime.now();
      final d = DateTime.now().difference(since);
      final mm = d.inMinutes.toString().padLeft(2, '0');
      final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
      timer = 'Connected · $mm:$ss';
      if (speakers.isNotEmpty) {
        final names = speakers.map(service.displayName).toList();
        status = names.length == 1
            ? '${names.single} is speaking'
            : '${names.sublist(0, names.length - 1).join(', ')} and '
                  '${names.last} are speaking';
      } else {
        status =
            'Connected with ${connected.map(service.displayName).join(', ')}';
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (connected.isNotEmpty && showParticipants)
          Padding(
            padding: EdgeInsets.only(bottom: compact ? 10 : 20),
            child: _Participants(
              service: service,
              peers: connected,
              compact: compact,
            ),
          ),
        _RoundButton(
          size: _size,
          color: Colors.red,
          icon: Icons.call_end,
          label: connected.isEmpty ? 'CANCEL' : 'HANG UP',
          onTap: service.hangUp,
          pulse: connected.isEmpty,
        ),
        SizedBox(height: compact ? 10 : 16),
        Text(
          status,
          textAlign: TextAlign.center,
          style: (compact ? text.titleMedium : text.titleLarge)?.copyWith(
            color: connected.isEmpty ? null : scheme.primary,
            fontWeight: speakers.isNotEmpty ? FontWeight.w600 : null,
          ),
        ),
        if (timer != null) Text(timer, style: text.bodySmall),
        if (conv.group && calling.isNotEmpty && connected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Waiting for ${calling.map(service.displayName).join(', ')}',
              style: text.bodySmall,
            ),
          ),
        SizedBox(height: compact ? 8 : 16),
        Wrap(
          spacing: 12,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: service.toggleMute,
              icon: Icon(service.muted ? Icons.mic_off : Icons.mic),
              label: Text(service.muted ? 'Unmute' : 'Mute'),
              style: service.muted
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.errorContainer,
                      foregroundColor: scheme.onErrorContainer,
                    )
                  : null,
            ),
            if (Platform.isAndroid) const AudioOutputButton(),
            if (connected.isNotEmpty && video != null && VideoCall.supported)
              CameraButtons(video: video!, onMessage: onMessage),
          ],
        ),
      ],
    );
  }
}

/// One card per connected peer plus "You". Whoever is speaking gets a
/// glowing ring, level bars and a "Speaking" label.
class _Participants extends StatelessWidget {
  const _Participants({
    required this.service,
    required this.peers,
    required this.compact,
  });

  final IntercomService service;
  final List<String> peers;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final echoLowered = service.micGain < 0.5;
    return Wrap(
      spacing: compact ? 12 : 20,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (final id in peers)
          _SpeakerTile(
            name: service.displayName(id),
            speaking: service.isSpeaking(id),
            level: service.peerLevel(id),
            compact: compact,
          ),
        _SpeakerTile(
          name: 'You',
          speaking: service.selfSpeaking,
          level: service.muted ? 0 : service.micLevel,
          compact: compact,
          muted: service.muted,
          note: echoLowered && !service.muted ? 'mic lowered (echo)' : null,
        ),
      ],
    );
  }
}

class _SpeakerTile extends StatelessWidget {
  const _SpeakerTile({
    required this.name,
    required this.speaking,
    required this.level,
    required this.compact,
    this.muted = false,
    this.note,
  });

  final String name;
  final bool speaking;
  final double level;
  final bool compact;
  final bool muted;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = compact ? 26.0 : 34.0;
    final ring = speaking ? Colors.green : scheme.outlineVariant;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return SizedBox(
      width: compact ? 84 : 104,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.all(speaking ? 3 + 4 * level : 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ring,
              boxShadow: speaking
                  ? [
                      BoxShadow(
                        color: Colors.green.withValues(alpha: 0.45),
                        blurRadius: 8 + 14 * level,
                        spreadRadius: 1 + 3 * level,
                      ),
                    ]
                  : null,
            ),
            child: CircleAvatar(
              radius: r,
              backgroundColor: speaking
                  ? Colors.green.shade100
                  : scheme.surfaceContainerHighest,
              foregroundColor: speaking
                  ? Colors.green.shade900
                  : scheme.onSurfaceVariant,
              child: muted
                  ? Icon(Icons.mic_off, size: r * 0.9)
                  : Text(initial, style: TextStyle(fontSize: r * 0.8)),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelLarge?.copyWith(
              fontWeight: speaking ? FontWeight.bold : null,
            ),
          ),
          SizedBox(
            height: 16,
            child: speaking
                ? _LevelBars(level: level)
                : Text(
                    muted ? 'muted' : (note ?? ''),
                    style: text.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small equalizer-style bars that move with the voice level.
class _LevelBars extends StatelessWidget {
  const _LevelBars({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    const shape = [0.55, 1.0, 0.75, 0.9, 0.6];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final f in shape)
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            width: 4,
            height: 3 + 13 * (level * f).clamp(0.0, 1.0),
            decoration: BoxDecoration(
              color: Colors.green,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}

/// Large round action button.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.size,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
    this.pulse = false,
  });

  final double size;
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: color,
      shape: const CircleBorder(),
      elevation: onTap == null ? 0 : 6,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: size * 0.36, color: Colors.white),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  fontSize: size * 0.085,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      child: pulse ? _Pulse(child: button) : button,
    );
  }
}

/// Gentle pulsing while a connection is being set up.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween(
      begin: 0.95,
      end: 1.03,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: widget.child,
  );
}

/// Android: shows the current audio output (speaker, earpiece, Bluetooth,
/// wired headset) and lets the user pick another.
class AudioOutputButton extends StatelessWidget {
  const AudioOutputButton({super.key});

  static IconData iconFor(AudioRouteType t) => switch (t) {
    AudioRouteType.speaker => Icons.volume_up,
    AudioRouteType.earpiece => Icons.phone_in_talk,
    AudioRouteType.bluetooth => Icons.bluetooth_audio,
    AudioRouteType.wired => Icons.headset,
    AudioRouteType.other => Icons.speaker,
  };

  @override
  Widget build(BuildContext context) {
    final routes = AudioRoutes.instance;
    return ListenableBuilder(
      listenable: routes,
      builder: (context, _) {
        final cur = routes.current;
        return FilledButton.tonalIcon(
          onPressed: () => _pick(context),
          icon: Icon(cur == null ? Icons.speaker : iconFor(cur.type)),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              cur?.name ?? 'Audio output',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  Future<void> _pick(BuildContext context) async {
    final routes = AudioRoutes.instance;
    await routes.refresh();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: routes,
        builder: (ctx, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Audio output',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (routes.routes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No audio outputs found.'),
                ),
              for (final r in routes.routes)
                ListTile(
                  leading: Icon(iconFor(r.type)),
                  title: Text(r.name),
                  subtitle: switch (r.type) {
                    AudioRouteType.bluetooth => const Text(
                      'Bluetooth headset (uses its microphone)',
                    ),
                    AudioRouteType.wired => const Text('Wired headset'),
                    _ => null,
                  },
                  trailing: r.id == routes.current?.id
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(ctx).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await routes.select(r);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Camera on/off, and switching camera (Android: front ⇄ back; Windows/Linux:
/// choose the built-in or a USB webcam). The camera only turns on when the
/// user presses the button.
class CameraButtons extends StatelessWidget {
  const CameraButtons({super.key, required this.video, this.onMessage});

  final VideoCall video;
  final void Function(String message, {bool error})? onMessage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: video,
      builder: (context, _) {
        final on = video.on;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonalIcon(
              onPressed: video.busy ? null : () => _run(video.toggle),
              icon: Icon(on ? Icons.videocam : Icons.videocam_off),
              label: Text(on ? 'Camera off' : 'Camera on'),
              style: on
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    )
                  : null,
            ),
            if (on && Platform.isAndroid && video.canSwitch) ...[
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: video.camera?.facing == CameraFacing.front
                    ? 'Switch to back camera'
                    : 'Switch to front camera',
                onPressed: video.busy ? null : () => _run(video.switchCamera),
                icon: const Icon(Icons.cameraswitch),
              ),
            ],
            if (Platform.isWindows || Platform.isLinux) ...[
              const SizedBox(width: 8),
              _WebcamMenu(video: video, run: _run),
            ],
          ],
        );
      },
    );
  }

  Future<void> _run(Future<Object?> Function() action) async {
    final result = await action();
    if (result is String) onMessage?.call(result, error: true);
  }
}

/// Windows/Linux: pick which webcam to use (built-in, USB, ...).
class _WebcamMenu extends StatelessWidget {
  const _WebcamMenu({required this.video, required this.run});

  final VideoCall video;
  final Future<void> Function(Future<Object?> Function() action) run;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      onOpen: video.refreshCameras,
      menuChildren: [
        if (video.cameras.isEmpty)
          const MenuItemButton(child: Text('No camera found')),
        for (final c in video.cameras)
          MenuItemButton(
            leadingIcon: const Icon(Icons.videocam),
            trailingIcon: video.on && c.id == video.camera?.id
                ? const Icon(Icons.check)
                : null,
            onPressed: () => run(() => video.select(c.id)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
          ),
      ],
      builder: (context, controller, _) => IconButton.filledTonal(
        tooltip: 'Choose camera',
        onPressed: video.busy
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.switch_video),
      ),
    );
  }
}
