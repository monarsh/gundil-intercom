import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';
import 'widgets.dart';

/// List of every known peer. Tapping one selects it; the call button calls it
/// directly (ending any other call), which is the quick way to switch peers.
class PeerList extends StatelessWidget {
  const PeerList({
    super.key,
    required this.service,
    required this.onSelect,
    required this.onAddPeer,
    this.highlightSelection = true,
  });

  final IntercomService service;
  final void Function(Peer peer) onSelect;
  final VoidCallback onAddPeer;
  final bool highlightSelection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final peers = service.peers;
        if (peers.isEmpty) return _empty(context);
        final online = peers.where((p) => p.online).length;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '$online online · ${peers.length} known',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            for (final p in peers) _tile(context, p),
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, Peer p) {
    final call = service.call;
    final inCallWith = call != null && call.peerId == p.id;
    final selected = highlightSelection && service.selectedPeerId == p.id;
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      leading: PeerAvatar(peer: p),
      title: Text(p.name, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Icon(platformIcon(p.platform), size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              inCallWith
                  ? switch (call.state) {
                      CallState.active => 'In call',
                      CallState.outgoing => 'Calling…',
                      CallState.incoming => 'Calling you…',
                      CallState.idle => '',
                    }
                  : p.address.address,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.unread > 0)
            Badge(label: Text('${p.unread}'), child: const SizedBox()),
          const SizedBox(width: 8),
          if (inCallWith)
            IconButton.filled(
              tooltip: 'End call',
              style: IconButton.styleFrom(backgroundColor: Colors.red),
              onPressed: service.hangup,
              icon: const Icon(Icons.call_end),
            )
          else
            IconButton.filledTonal(
              tooltip: call == null
                  ? 'Call ${p.name}'
                  : 'Switch call to ${p.name}',
              onPressed: p.online ? () => service.callPeer(p.id) : null,
              icon: Icon(call == null ? Icons.call : Icons.swap_calls),
            ),
        ],
      ),
      onTap: () => onSelect(p),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              'Looking for peers on the local network…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Start P2P Intercom on another device on the same Wi-Fi/LAN, '
              'or add one by IP address.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onAddPeer,
              icon: const Icon(Icons.add_link),
              label: const Text('Add peer by IP'),
            ),
          ],
        ),
      ),
    );
  }
}
