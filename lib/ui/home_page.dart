import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/autostart.dart';
import '../src/intercom_service.dart';
import '../src/protocol.dart';
import '../src/settings.dart';
import 'peer_dialog.dart';
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

  // ---------------------------------------------------------------- dialogs

  Future<void> _addPeerDialog() async {
    final r = await showPeerDialog(
      context,
      title: 'Add peer',
      confirmText: 'Add',
    );
    _focus.requestFocus();
    if (r == null || !mounted) return;
    try {
      final online = await service.addSavedPeer(
        host: r.host,
        port: r.port,
        label: r.label,
      );
      final name = r.label.isEmpty ? '${r.host}:${r.port}' : r.label;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            online
                ? 'Connected to $name'
                : 'Saved $name. It is offline right now — '
                      'it will connect when it comes online.',
          ),
        ),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text('${e.message}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _settingsDialog() async {
    final nameCtl = TextEditingController(text: service.name);
    final addrs = await _localAddresses();
    final autostartWas = await Autostart.isEnabled();
    var autostart = autostartWas;
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
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Device name shown to peers',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                if (Autostart.supported) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      Platform.isWindows
                          ? 'Start with Windows'
                          : 'Start automatically at login',
                    ),
                    subtitle: const Text(
                      'Opens minimized when you sign in, ready to receive.',
                    ),
                    value: autostart,
                    onChanged: (v) => setLocal(() => autostart = v),
                  ),
                ],
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
      ),
    );
    if (saved == true) {
      if (autostart != autostartWas) {
        final now = await Autostart.setEnabled(autostart);
        if (now != autostart && mounted) {
          _messenger.currentState?.showSnackBar(
            const SnackBar(
              content: Text('Could not change the autostart setting'),
            ),
          );
        }
      }
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
                      const Text('Gundil Intercom'),
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
