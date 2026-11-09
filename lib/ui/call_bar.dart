import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';
import 'widgets.dart';

/// Persistent strip shown at the top of every screen while a call is ringing
/// or in progress. Holds the call controls.
class CallBar extends StatelessWidget {
  const CallBar({super.key, required this.service, this.onOpenPeer});

  final IntercomService service;
  final void Function(String peerId)? onOpenPeer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final call = service.call;
        if (call == null) return const SizedBox.shrink();
        final peer = service.peer(call.peerId);
        final scheme = Theme.of(context).colorScheme;
        final incoming = call.state == CallState.incoming;
        final bg = incoming
            ? scheme.tertiaryContainer
            : scheme.primaryContainer;
        final fg = incoming
            ? scheme.onTertiaryContainer
            : scheme.onPrimaryContainer;

        final status = switch (call.state) {
          CallState.incoming => 'Incoming call…',
          CallState.outgoing => 'Calling…',
          CallState.active => formatDuration(
            DateTime.now().difference(call.startedAt ?? DateTime.now()),
          ),
          CallState.idle => '',
        };

        return Material(
          color: bg,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(incoming ? Icons.ring_volume : Icons.call, color: fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: onOpenPeer == null
                          ? null
                          : () => onOpenPeer!(call.peerId),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            peer?.name ?? 'Unknown peer',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.titleMedium?.copyWith(color: fg),
                          ),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  status,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: fg),
                                ),
                              ),
                              if (call.state == CallState.active &&
                                  !service.muted) ...[
                                const SizedBox(width: 10),
                                LevelMeter(level: service.micLevel, width: 60),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  ..._buttons(context, call, fg),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buttons(BuildContext context, CallInfo call, Color fg) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    Widget action(
      String label,
      IconData icon,
      Color color,
      VoidCallback onTap,
    ) {
      if (compact) {
        return IconButton.filled(
          tooltip: label,
          style: IconButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
          ),
          onPressed: onTap,
          icon: Icon(icon),
        );
      }
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
        ),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      );
    }

    if (call.state == CallState.incoming) {
      return [
        action('Decline', Icons.call_end, Colors.red, service.reject),
        const SizedBox(width: 8),
        action('Answer', Icons.call, Colors.green, service.accept),
      ];
    }
    return [
      if (call.state == CallState.active) ...[
        IconButton(
          tooltip: service.muted ? 'Unmute microphone' : 'Mute microphone',
          onPressed: service.toggleMute,
          color: fg,
          isSelected: service.muted,
          icon: const Icon(Icons.mic),
          selectedIcon: const Icon(Icons.mic_off),
        ),
        if (Theme.of(context).platform == TargetPlatform.android)
          IconButton(
            tooltip: service.speaker ? 'Use earpiece' : 'Use loudspeaker',
            onPressed: service.toggleSpeaker,
            color: fg,
            icon: Icon(service.speaker ? Icons.volume_up : Icons.hearing),
          ),
      ],
      const SizedBox(width: 4),
      action(
        call.state == CallState.outgoing ? 'Cancel' : 'Hang up',
        Icons.call_end,
        Colors.red,
        service.hangup,
      ),
    ];
  }
}
