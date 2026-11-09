import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';

/// Push-to-talk area: shows who is talking / who you'll talk to, and the big
/// hold-to-talk button.
class PttPanel extends StatelessWidget {
  const PttPanel({super.key, required this.service, this.compact = false});

  final IntercomService service;

  /// Smaller layout for phones (button under the peer list).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final scheme = Theme.of(context).colorScheme;
        final targetName = service.targetName(service.target);
        final incoming = service.incoming;
        final talkerName = incoming == null
            ? null
            : service.peer(incoming.peerId)?.name ?? 'Someone';

        final String status;
        if (service.transmitting) {
          status = 'Talking to $targetName';
        } else if (service.pttHeld) {
          status = 'Connecting…';
        } else {
          status = 'Hold to talk to $targetName';
        }

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: compact ? 12 : 24,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Receiving(name: talkerName, group: incoming?.group ?? false),
              SizedBox(height: compact ? 8 : 24),
              PttButton(service: service, size: compact ? 150 : 210),
              SizedBox(height: compact ? 10 : 20),
              Text(
                status,
                textAlign: TextAlign.center,
                style: (compact ? text.titleMedium : text.titleLarge)?.copyWith(
                  color: service.transmitting ? scheme.error : null,
                ),
              ),
              if (!compact &&
                  Theme.of(context).platform != TargetPlatform.android) ...[
                const SizedBox(height: 6),
                Text('or hold the Space bar', style: text.bodySmall),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// "X is talking" indicator (keeps its height when idle so nothing jumps).
class _Receiving extends StatelessWidget {
  const _Receiving({required this.name, required this.group});

  final String? name;
  final bool group;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = name != null;
    return AnimatedOpacity(
      opacity: active ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up, color: scheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                active ? '$name is talking${group ? ' to everyone' : ''}' : ' ',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Large round hold-to-talk button with a microphone level ring.
class PttButton extends StatelessWidget {
  const PttButton({super.key, required this.service, this.size = 200});

  final IntercomService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final held = service.pttHeld;
    final live = service.transmitting;
    final hasTarget =
        service.target is EveryoneTarget ||
        (service.peer((service.target as PeerTarget).peerId)?.online ?? false);
    final color = live
        ? Colors.red
        : hasTarget
        ? scheme.primary
        : scheme.outline;

    return Semantics(
      button: true,
      label: 'Push to talk',
      child: Listener(
        onPointerDown: (_) => service.startTalking(),
        onPointerUp: (_) => service.stopTalking(),
        onPointerCancel: (_) => service.stopTalking(),
        child: SizedBox(
          width: size + 24,
          height: size + 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Level ring.
              AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: size + 24 * (live ? service.micLevel : 0),
                height: size + 24 * (live ? service.micLevel : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.25),
                ),
              ),
              AnimatedScale(
                scale: held ? 0.94 : 1,
                duration: const Duration(milliseconds: 80),
                child: Material(
                  color: color,
                  shape: const CircleBorder(),
                  elevation: held ? 2 : 8,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          live ? Icons.mic : Icons.mic_none,
                          size: size * 0.38,
                          color: Colors.white,
                        ),
                        Text(
                          live ? 'ON AIR' : 'PUSH TO TALK',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            fontSize: size * 0.075,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
