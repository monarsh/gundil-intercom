import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/intercom_service.dart';
import '../src/protocol.dart';
import '../src/settings.dart';
import 'peer_list.dart';
import 'ptt_panel.dart';

/// Main window.
///
/// * Wide screens (desktop, tablets): channel list on the left, big
///   push-to-talk button on the right.
/// * Narrow screens (phones): channel list on top, push-to-talk at the bottom.
///
/// Pick a channel (Everyone or one peer), then hold the button — or the Space
/// bar on desktop — to talk.
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
  final FocusNode _focus = FocusNode(debugLabel: 'ptt-keyboard');

  IntercomService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventSub = service.events.listen((e) {
      if (!mounted) return;
      _messenger.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(e.message),
            duration: const Duration(seconds: 2),
            backgroundColor: e.error
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        );
    });
    _restoreManualPeers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never leave the microphone open in the background.
    if (state != AppLifecycleState.resumed) service.stopTalking();
    if (state == AppLifecycleState.detached) service.shutdown();
  }

  /// Space bar = push-to-talk on desktop.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      service.startTalking();
    } else if (event is KeyUpEvent) {
      service.stopTalking();
    }
    return KeyEventResult.handled; // also swallows KeyRepeatEvent
  }

  Future<void> _restoreManualPeers() async {
    for (final entry in widget.settings.manualPeers) {
      final (host, port) = _parseEndpoint(entry);
      if (host == null) continue;
      try {
        await service.addManualPeer(host, port: port);
      } catch (_) {
        // Peer offline right now; it will reappear via discovery.
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

  // ---------------------------------------------------------------- dialogs

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
              'Use this when automatic discovery is blocked (some routers, '
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
    _focus.requestFocus();
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
    final addrs = await _localAddresses();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Device name shown to peers',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 16),
              Text('This device', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText(
                'Addresses: ${addrs.isEmpty ? 'none' : addrs.join(', ')}\n'
                'TCP port: ${service.listenPort}\n'
                'Discovery: ${service.discoveryRunning ? 'UDP $discoveryPort broadcast' : 'off'}',
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
    );
    if (saved == true) {
      final name = nameCtl.text.trim();
      if (name.isNotEmpty) {
        service.name = name;
        widget.settings.name = name;
      }
    }
    nameCtl.dispose();
    _focus.requestFocus();
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
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
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
              body: wide ? _wideBody() : _narrowBody(),
            );
          },
        ),
      ),
    );
  }

  Widget _wideBody() {
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: PeerList(service: service, onAddPeer: _addPeerDialog),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Center(child: PttPanel(service: service)),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    return Column(
      children: [
        Expanded(
          child: PeerList(service: service, onAddPeer: _addPeerDialog),
        ),
        const Divider(height: 1),
        SafeArea(top: false, child: PttPanel(service: service, compact: true)),
      ],
    );
  }
}
