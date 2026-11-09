import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import '../src/models.dart';
import '../src/protocol.dart';
import '../src/settings.dart';
import 'call_bar.dart';
import 'peer_list.dart';
import 'peer_panel.dart';

/// Main window.
///
/// * Wide screens (desktop, tablets): peer list on the left, selected peer on
///   the right — switching peers is a single click.
/// * Narrow screens (phones): peer list; tapping a peer opens its page.
///
/// A [CallBar] with the call controls stays on top in both layouts.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.service, required this.settings});

  final IntercomService service;
  final Settings settings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const double _wideBreakpoint = 720;

  late final StreamSubscription<IntercomEvent> _eventSub;
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();
  final GlobalKey<NavigatorState> _phoneNav = GlobalKey<NavigatorState>();

  IntercomService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventSub = service.events.listen((e) {
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: e.error ? Theme.of(context).colorScheme.error : null,
        ),
      );
    });
    _restoreManualPeers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) service.shutdown();
  }

  Future<void> _restoreManualPeers() async {
    for (final entry in widget.settings.manualPeers) {
      final (host, port) = _parseEndpoint(entry);
      if (host == null) continue;
      try {
        await service.addManualPeer(host, port: port);
      } catch (_) {
        // Peer offline right now; it will reappear via discovery or a retry.
      }
    }
  }

  static (String?, int) _parseEndpoint(String s) {
    final t = s.trim();
    if (t.isEmpty) return (null, defaultTcpPort);
    final i = t.lastIndexOf(':');
    if (i > 0 && !t.substring(0, i).contains(':')) {
      final p = int.tryParse(t.substring(i + 1));
      if (p != null && p > 0 && p < 65536) return (t.substring(0, i), p);
    }
    return (t, defaultTcpPort);
  }

  // ---------------------------------------------------------------- actions

  void _openPeer(Peer p, {required bool wide}) {
    service.selectPeer(p.id);
    if (wide) return;
    final nav = _phoneNav.currentState!;
    nav.popUntil((r) => r.isFirst);
    nav
        .push(
          MaterialPageRoute<void>(
            builder: (_) => _PhonePeerPage(service: service, peer: p),
          ),
        )
        .then((_) {
          if (service.selectedPeerId == p.id) service.selectPeer(null);
        });
  }

  void _openPeerById(String id, {required bool wide}) {
    final p = service.peer(id);
    if (p != null) _openPeer(p, wide: wide);
  }

  Future<void> _addPeerDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add peer by IP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Use this when broadcast discovery is blocked (some routers, '
              'VPNs or different subnets).',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'IP address or host[:port]',
                hintText: '192.168.1.42',
                helperText: 'Default port $defaultTcpPort',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final (host, port) = _parseEndpoint(result);
    if (host == null) return;
    try {
      final p = await service.addManualPeer(host, port: port);
      final saved = widget.settings.manualPeers;
      final entry = '$host:$port';
      if (!saved.contains(entry)) {
        widget.settings.manualPeers = [...saved, entry];
      }
      _messenger.currentState?.showSnackBar(
        SnackBar(content: Text('Connected to ${p.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text('Could not connect to $host:$port — $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _settingsDialog() async {
    final nameCtl = TextEditingController(text: service.name);
    var autoAnswer = service.autoAnswer;
    final addrs = await _localAddresses();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Settings'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: 'Device name shown to peers',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-answer (intercom mode)'),
                  subtitle: const Text(
                    'Incoming calls connect immediately without ringing.',
                  ),
                  value: autoAnswer,
                  onChanged: (v) => setLocal(() => autoAnswer = v),
                ),
                const Divider(),
                Text('This device', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                SelectableText(
                  'Addresses: ${addrs.isEmpty ? 'none' : addrs.join(', ')}\n'
                  'TCP port: ${service.listenPort}\n'
                  'Discovery: ${service.discoveryRunning ? 'UDP $discoveryPort broadcast' : 'off'}\n'
                  'ID: ${service.selfId}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      final name = nameCtl.text.trim();
      if (name.isNotEmpty) {
        service.name = name;
        widget.settings.name = name;
      }
      service.autoAnswer = autoAnswer;
      widget.settings.autoAnswer = autoAnswer;
    }
    nameCtl.dispose();
  }

  static Future<List<String>> _localAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in ifaces)
          for (final a in i.addresses) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messenger,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideBreakpoint;
          return Scaffold(
            appBar: AppBar(
              title: ListenableBuilder(
                listenable: service,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('P2P Intercom'),
                    Text(
                      'You are “${service.name}”',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Add peer by IP',
                  onPressed: _addPeerDialog,
                  icon: const Icon(Icons.add_link),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: _settingsDialog,
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
            body: Column(
              children: [
                CallBar(
                  service: service,
                  onOpenPeer: (id) => _openPeerById(id, wide: wide),
                ),
                Expanded(child: wide ? _wideBody() : _narrowBody()),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _wideBody() {
    return Row(
      children: [
        SizedBox(
          width: 320,
          child: PeerList(
            service: service,
            onSelect: (p) => _openPeer(p, wide: true),
            onAddPeer: _addPeerDialog,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              final id = service.selectedPeerId;
              if (id == null || service.peer(id) == null) {
                return const _Placeholder();
              }
              return PeerPanel(key: ValueKey(id), service: service, peerId: id);
            },
          ),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    // Nested navigator so the call bar and app bar stay put while the user
    // moves between the peer list and a peer page.
    return NavigatorPopHandler(
      onPopWithResult: (_) => _phoneNav.currentState?.maybePop(),
      child: Navigator(
        key: _phoneNav,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => PeerList(
            service: service,
            highlightSelection: false,
            onSelect: (p) => _openPeer(p, wide: false),
            onAddPeer: _addPeerDialog,
          ),
        ),
      ),
    );
  }
}

class _PhonePeerPage extends StatelessWidget {
  const _PhonePeerPage({required this.service, required this.peer});

  final IntercomService service;
  final Peer peer;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('All peers'),
            ),
          ),
          Expanded(
            child: PeerPanel(service: service, peerId: peer.id),
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.settings_input_antenna,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'Select a peer to talk to',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
