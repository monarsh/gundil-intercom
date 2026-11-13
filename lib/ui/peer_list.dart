import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import 'peer_dialog.dart';
import 'widgets.dart';

enum _PeerAction { edit, save, remove }

/// Channel selector: "Everyone" plus every known peer. The selected entry is
/// who CONNECT opens a two-way line with; tapping another one switches.
///
/// Saved peers (bookmark icon) stay in the list across restarts, even when
/// offline. Every peer has a ⋮ menu to edit, save or remove it (online or
/// offline).
class PeerList extends StatelessWidget {
  const PeerList({super.key, required this.service, required this.onAddPeer});

  final IntercomService service;
  final VoidCallback onAddPeer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final entries = service.entries;
        final online = entries.where((e) => e.online).length;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _everyone(context, online),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries.isEmpty
                          ? 'Peers'
                          : 'Peers · $online online of ${entries.length}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onAddPeer,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
            ),
            if (entries.isEmpty) _empty(context),
            for (final e in entries) _tile(context, e),
          ],
        );
      },
    );
  }

  Widget _everyone(BuildContext context, int online) {
    final scheme = Theme.of(context).colorScheme;
    final selected = service.target is EveryoneTarget;
    final conv = service.conversation;
    final groupActive = conv != null && conv.group && conv.outgoing;
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
      trailing: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: groupActive
            ? const Icon(Icons.call, color: Colors.green)
            : _radio(selected),
      ),
      onTap: () => service.selectTarget(const EveryoneTarget()),
    );
  }

  Widget _tile(BuildContext context, PeerEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final id = e.peerId;
    final selected = id != null && service.target == PeerTarget(id);
    final state = id == null ? null : service.memberState(id);
    final muted = e.online ? null : scheme.onSurface.withValues(alpha: 0.45);

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: PeerAvatar(name: e.name, online: e.online),
      title: Row(
        children: [
          Flexible(
            child: Text(
              e.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted),
            ),
          ),
          if (e.isSaved) ...[
            const SizedBox(width: 6),
            Icon(Icons.bookmark, size: 14, color: muted ?? scheme.primary),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          Icon(platformIcon(e.platform), size: 14, color: muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              switch (state) {
                MemberState.connected when service.isReconnecting(id!) =>
                  'Reconnecting…',
                MemberState.connected when service.isSpeaking(id!) =>
                  'Speaking…',
                MemberState.connected => 'Connected',
                MemberState.calling => 'Calling…',
                MemberState.ringing => 'Wants to talk',
                null when e.live?.outdated ?? false =>
                  'Needs update (no encryption)',
                null when e.live?.wrongPassword ?? false =>
                  'Different intercom password',
                null => e.online ? e.host : 'Offline · ${e.host}',
              },
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == MemberState.connected && service.isSpeaking(id!))
            const Icon(Icons.graphic_eq, color: Colors.green)
          else if (state != null)
            Icon(switch (state) {
              MemberState.connected => Icons.call,
              MemberState.calling => Icons.phone_forwarded,
              MemberState.ringing => Icons.ring_volume,
            }, color: Colors.green)
          else if (e.online)
            _radio(selected),
          _menu(context, e),
        ],
      ),
      onTap: () {
        if (e.online && id != null) {
          service.selectTarget(PeerTarget(id));
        } else {
          _snack(context, '${e.name} is offline');
        }
      },
      onLongPress: () => _edit(context, e),
    );
  }

  Widget _menu(BuildContext context, PeerEntry e) {
    return PopupMenuButton<_PeerAction>(
      tooltip: 'Peer options',
      icon: const Icon(Icons.more_vert),
      onSelected: (a) => switch (a) {
        _PeerAction.edit => _edit(context, e),
        _PeerAction.save => _save(context, e),
        _PeerAction.remove => _remove(context, e),
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _PeerAction.edit,
          child: ListTile(
            leading: const Icon(Icons.edit),
            title: Text(e.isSaved ? 'Edit…' : 'Rename…'),
          ),
        ),
        if (!e.isSaved)
          const PopupMenuItem(
            value: _PeerAction.save,
            child: ListTile(
              leading: Icon(Icons.bookmark_add),
              title: Text('Keep in list'),
            ),
          ),
        const PopupMenuItem(
          value: _PeerAction.remove,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Remove'),
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, PeerEntry e) async {
    final saved = e.saved;
    if (saved == null) {
      // Discovered peer: rename = save it with a custom label.
      final r = await showPeerDialog(
        context,
        title: 'Rename peer',
        label: '',
        nameHint: e.name,
        host: e.host,
        port: e.port,
        hostEditable: false,
      );
      if (r == null) return;
      service.saveLivePeer(e.live!.id, label: r.label);
      return;
    }
    final r = await showPeerDialog(
      context,
      title: 'Edit peer',
      label: saved.label,
      nameHint: e.live?.name,
      host: saved.host,
      port: saved.port,
    );
    if (r == null || !context.mounted) return;
    try {
      final addressChanged = r.host != saved.host || r.port != saved.port;
      final online = await service.updateSavedPeer(
        saved.key,
        label: r.label,
        host: r.host,
        port: r.port,
      );
      if (addressChanged && !online && context.mounted) {
        _snack(
          context,
          'Saved. ${r.host}:${r.port} is not reachable right now — '
          'will keep trying.',
        );
      }
    } on ArgumentError catch (err) {
      if (context.mounted) _snack(context, '${err.message}', error: true);
    }
  }

  void _save(BuildContext context, PeerEntry e) {
    service.saveLivePeer(e.live!.id);
    _snack(context, '${e.name} will stay in the list');
  }

  Future<void> _remove(BuildContext context, PeerEntry e) async {
    final known = e.peerId != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${e.name}?'),
        content: Text(
          known
              ? 'It disappears from the list, even while it is online, and '
                    'can\'t connect to you. To get it back, add it again '
                    'with "Add peer by IP", or use "Show removed peers" in '
                    'Settings.'
              : 'It is removed from your saved peers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    service.removePeer(e);
    if (context.mounted) _snack(context, '${e.name} removed');
  }

  void _snack(BuildContext context, String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
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
