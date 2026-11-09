import 'package:flutter/material.dart';

import '../src/models.dart';

IconData platformIcon(String platform) => switch (platform) {
  'android' => Icons.phone_android,
  'windows' => Icons.desktop_windows,
  'linux' => Icons.computer,
  'macos' => Icons.laptop_mac,
  'ios' => Icons.phone_iphone,
  _ => Icons.devices_other,
};

String platformLabel(String platform) => switch (platform) {
  'android' => 'Android',
  'windows' => 'Windows',
  'linux' => 'Linux',
  'macos' => 'macOS',
  'ios' => 'iOS',
  _ => platform,
};

/// Round avatar with the peer's initial and a presence dot.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.peer, this.radius = 22});

  final Peer peer;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = peer.name.isEmpty ? '?' : peer.name[0].toUpperCase();
    final dot = radius * 0.55;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: peer.online
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          foregroundColor: peer.online
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
          child: Text(initial, style: TextStyle(fontSize: radius * 0.8)),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: peer.online ? Colors.green : scheme.outline,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
