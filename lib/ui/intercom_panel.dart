import 'dart:io';

import 'package:flutter/material.dart';

import '../src/intercom_service.dart';

/// Main control area: connect / hang up the two-way audio line, accept or
/// decline when someone rings, mute and speaker controls.
class IntercomPanel extends StatelessWidget {
  const IntercomPanel({super.key, required this.service, this.compact = false});

  final IntercomService service;

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

  double get _size => compact ? 132 : 200;

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
    if (connected.isEmpty) {
      status = conv.group
          ? 'Connecting to everyone…'
          : 'Connecting to ${calling.map(service.displayName).join(', ')}…';
    } else {
      final since = conv.connectedAt ?? DateTime.now();
      final d = DateTime.now().difference(since);
      final mm = d.inMinutes.toString().padLeft(2, '0');
      final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
      final names = connected.map(service.displayName).join(', ');
      status = 'Connected with $names · $mm:$ss';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (connected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Meters(service: service, compact: compact),
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
          ),
        ),
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
            if (Platform.isAndroid)
              FilledButton.tonalIcon(
                onPressed: service.toggleSpeaker,
                icon: Icon(service.speaker ? Icons.volume_up : Icons.hearing),
                label: Text(service.speaker ? 'Speaker' : 'Earpiece'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Microphone / speaker level meters.
class _Meters extends StatelessWidget {
  const _Meters({required this.service, required this.compact});

  final IntercomService service;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final width = compact ? 110.0 : 160.0;
    Widget meter(IconData icon, double level, Color color, String tip) =>
        Tooltip(
          message: tip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              SizedBox(
                width: width,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: level, color: color),
                ),
              ),
            ],
          ),
        );
    final ducked = service.micGain < 0.5;
    return Wrap(
      spacing: 20,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        meter(
          service.muted ? Icons.mic_off : Icons.mic,
          service.muted ? 0 : service.micLevel,
          ducked ? Colors.orange : Colors.green,
          ducked ? 'Your mic (lowered to stop echo)' : 'Your mic',
        ),
        meter(Icons.volume_up, service.speakerLevel, Colors.blue, 'Speaker'),
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
