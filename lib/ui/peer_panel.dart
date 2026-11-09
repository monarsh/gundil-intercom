import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';
import 'widgets.dart';

/// Detail view for one peer: identity, call button and text chat.
class PeerPanel extends StatefulWidget {
  const PeerPanel({super.key, required this.service, required this.peerId});

  final IntercomService service;
  final String peerId;

  @override
  State<PeerPanel> createState() => _PeerPanelState();
}

class _PeerPanelState extends State<PeerPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  IntercomService get service => widget.service;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    try {
      await service.sendText(widget.peerId, text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Message not delivered: $e')));
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final peer = service.peer(widget.peerId);
        if (peer == null) {
          return const Center(child: Text('This peer is no longer available.'));
        }
        if (peer.messages.length != _lastCount) {
          _lastCount = peer.messages.length;
          _scrollToEnd();
        }
        return Column(
          children: [
            _header(context, peer),
            const Divider(height: 1),
            Expanded(child: _messages(context, peer)),
            const Divider(height: 1),
            _composer(context, peer),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, Peer peer) {
    final call = service.call;
    final inCall = call != null && call.peerId == peer.id;
    final text = Theme.of(context).textTheme;

    Widget action;
    if (inCall) {
      action = FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.red,
          minimumSize: const Size(140, 48),
        ),
        onPressed: call.state == CallState.incoming
            ? service.reject
            : service.hangup,
        icon: const Icon(Icons.call_end),
        label: Text(switch (call.state) {
          CallState.outgoing => 'Cancel',
          CallState.incoming => 'Decline',
          _ => 'Hang up',
        }),
      );
    } else {
      action = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
        onPressed: peer.online ? () => service.callPeer(peer.id) : null,
        icon: Icon(call == null ? Icons.call : Icons.swap_calls),
        label: Text(call == null ? 'Call' : 'Switch call here'),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PeerAvatar(peer: peer, radius: 28),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(peer.name, style: text.titleLarge),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(platformIcon(peer.platform), size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${platformLabel(peer.platform)} · ${peer.endpoint} · '
                        '${peer.online ? 'online' : 'offline'}',
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          action,
        ],
      ),
    );
  }

  Widget _messages(BuildContext context, Peer peer) {
    if (peer.messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet.\nPress Call to talk, or send a text below.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: peer.messages.length,
      itemBuilder: (context, i) {
        final m = peer.messages[i];
        final time =
            '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}';
        return Align(
          alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: m.mine
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SelectableText(m.text),
                  const SizedBox(height: 2),
                  Text(time, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _composer(BuildContext context, Peer peer) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: peer.online,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: peer.online
                      ? 'Message ${peer.name}'
                      : '${peer.name} is offline',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              onPressed: peer.online ? _send : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
