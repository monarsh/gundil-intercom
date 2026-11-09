import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';
import 'widgets.dart';

/// Channel selector: "Everyone" plus every known peer. The selected entry is
/// who push-to-talk transmits to; tapping another one switches instantly.
class PeerList extends StatelessWidget {
  const PeerList({super.key, required this.service, required this.onAddPeer});

  final IntercomService service;
  final VoidCallback onAddPeer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final peers = service.peers;
        final online = peers.where((p) => p.online).length;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _everyone(context, online),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                peers.isEmpty
                    ? 'Peers'
                    : 'Peers · $online online of ${peers.length}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            if (peers.isEmpty) _empty(context),
            for (final p in peers) _tile(context, p),
          ],
        );
      },
    );
  }

  Widget _everyone(BuildContext context, int online) {
    final scheme = Theme.of(context).colorScheme;
    final selected = service.target is EveryoneTarget;
    final talkingGroup = service.incoming?.group ?? false;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        child: const Icon(Icons.campaign),
      ),
      title: const Text('Everyone'),
      subtitle: Text(
        online == 0
            ? 'Nobody online yet'
            : 'Talk to all $online online peer${online == 1 ? '' : 's'}',
      ),
      trailing: talkingGroup
          ? const Icon(Icons.volume_up, color: Colors.green)
          : _radio(selected),
      onTap: () => service.selectTarget(const EveryoneTarget()),
    );
  }

  Widget _tile(BuildContext context, Peer p) {
    final scheme = Theme.of(context).colorScheme;
    final selected = service.target == PeerTarget(p.id);
    final talking = service.incoming?.peerId == p.id;
    return ListTile(
      enabled: p.online,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: PeerAvatar(peer: p),
      title: Text(p.name, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Icon(platformIcon(p.platform), size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              talking
                  ? 'Talking…'
                  : p.online
                  ? p.address.address
                  : 'Offline',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: talking
          ? const Icon(Icons.volume_up, color: Colors.green)
          : _radio(selected),
      onTap: () => service.selectTarget(PeerTarget(p.id)),
    );
  }

  Widget _radio(bool selected) => Icon(
    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
  );

  Widget _empty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 12),
          const Text(
            'Looking for other intercoms on this network…\n'
            'Start the app on another device on the same Wi-Fi/LAN.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onAddPeer,
            icon: const Icon(Icons.add_link),
            label: const Text('Add peer by IP'),
          ),
        ],
      ),
    );
  }
}
