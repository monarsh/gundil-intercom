import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../src/autostart.dart';
import '../src/intercom_service.dart';
import '../src/platform_bridge.dart';
import '../src/settings.dart';
import '../src/video_call.dart';
import '../src/window_bridge.dart';
import 'intercom_panel.dart';
import 'peer_dialog.dart';
import 'peer_list.dart';
import 'video_view.dart';
import 'volume_sheet.dart';

/// Main window.
///
/// * Wide screens (desktop, tablets): peer list on the left, the connect /
///   hang-up controls on the right.
/// * Narrow screens (phones): peer list on top, controls at the bottom.
///
/// Pick Everyone or one peer and press CONNECT: a two-way audio line opens
/// until either side hangs up.
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

  late final VideoCall _video = VideoCall(service)
    ..onError = (m) => _showMessage(m, error: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventSub = service.events.listen(
      (e) => _showMessage(e.message, error: e.error),
    );
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _video.dispose();
    _eventSub.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A two-way conversation deliberately continues in the background
    // (tray on Windows, background mode on Android).
    // On Android the engine may keep running without a window (background
    // mode), so only desktop shuts down when the window goes away.
    if (state == AppLifecycleState.detached && !Platform.isAndroid) {
      service.shutdown();
    }
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
    final passwordCtl = TextEditingController(text: service.password);
    var showPassword = false;
    final addrs = await _localAddresses();
    final autostartWas = await Autostart.isEnabled();
    var autostart = autostartWas;
    final trayWas = widget.settings.minimizeToTray;
    final trayAvailable = await WindowBridge.trayAvailable();
    var autoAnswer = service.autoAnswer;
    var echo = service.echoSuppression;
    var tray = trayWas;
    final backgroundWas = await PlatformBridge.getBackground();
    var background = backgroundWas;
    final bootWas = await PlatformBridge.getStartOnBoot();
    var boot = bootWas;
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Settings'),
          scrollable: true,
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
                const SizedBox(height: 12),
                TextField(
                  controller: passwordCtl,
                  obscureText: !showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Intercom password (optional)',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: showPassword ? 'Hide' : 'Show',
                      icon: Icon(
                        showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setLocal(() => showPassword = !showPassword),
                    ),
                    helperText:
                        'Calls are always encrypted. With a password, only '
                        'intercoms with the same password can connect: set '
                        'it on every device.',
                    helperMaxLines: 3,
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
                    subtitle: Text(
                      trayAvailable
                          ? 'Starts in the system tray when you sign in, '
                                'ready to receive.'
                          : 'Opens minimized when you log in, ready to '
                                'receive.',
                    ),
                    value: autostart,
                    onChanged: (v) => setLocal(() => autostart = v),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Answer automatically'),
                  subtitle: const Text(
                    'Incoming connections open at once, like an intercom. '
                    'Turn off to ring and accept/decline instead.',
                  ),
                  value: autoAnswer,
                  onChanged: (v) => setLocal(() => autoAnswer = v),
                ),
                if (!Platform.isAndroid)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Echo suppression'),
                    subtitle: const Text(
                      'Lowers your mic while the other side talks, so they '
                      "don't hear themselves. Turn off with a headset.",
                    ),
                    value: echo,
                    onChanged: (v) => setLocal(() => echo = v),
                  ),
                if (trayAvailable)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Minimize to tray'),
                    subtitle: Text(
                      Platform.isWindows
                          ? 'Minimize and the close button keep it running in '
                                'the notification area. Right-click the tray '
                                'icon > Exit to quit.'
                          : 'Minimize and the close button keep it running in '
                                "the tray. Use the tray icon's menu to open "
                                'it, or Exit to quit.',
                    ),
                    value: tray,
                    onChanged: (v) => setLocal(() => tray = v),
                  ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Run in background'),
                    subtitle: const Text(
                      'Keeps receiving when the app is closed or the screen '
                      'is off. Shows a notification.',
                    ),
                    value: background,
                    onChanged: (v) => setLocal(() {
                      background = v;
                      if (!v) boot = false;
                    }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start when phone turns on'),
                    subtitle: const Text('Needs "Run in background".'),
                    value: boot,
                    onChanged: background
                        ? (v) => setLocal(() => boot = v)
                        : null,
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
      service.autoAnswer = autoAnswer;
      widget.settings.autoAnswer = autoAnswer;
      service.echoSuppression = echo;
      widget.settings.echoSuppression = echo;
      if (tray != trayWas) {
        widget.settings.minimizeToTray = tray;
        await WindowBridge.setTrayEnabled(tray);
      }
      if (background != backgroundWas) {
        await _setBackground(background);
      }
      if (boot != bootWas) await PlatformBridge.setStartOnBoot(boot);
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
      final password = passwordCtl.text;
      if (password != service.password) {
        widget.settings.password = password;
        await service.setPassword(password);
        if (mounted) {
          _showMessage(
            password.isEmpty
                ? 'Password removed. Calls stay encrypted.'
                : 'Password set. Use the same one on every intercom.',
          );
        }
      }
    }
    nameCtl.dispose();
    passwordCtl.dispose();
    _focus.requestFocus();
  }

  /// Turns Android background mode on/off, asking for what it needs.
  Future<void> _setBackground(bool on) async {
    if (!on) {
      await PlatformBridge.setBackground(false);
      return;
    }
    // Android 13+: without this the notification is hidden (the service
    // still runs).
    await PlatformBridge.requestNotifications();
    await PlatformBridge.setBackground(true);
    if (!await PlatformBridge.isIgnoringBatteryOptimizations()) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow unrestricted battery use?'),
          content: const Text(
            'To keep hearing other intercoms while the screen is off, Android '
            'must not put Gundil Intercom to sleep. On the next screen, choose '
            '"Allow".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok == true) await PlatformBridge.requestIgnoreBatteryOptimizations();
    }
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
                  ListenableBuilder(
                    listenable: service,
                    builder: (context, _) => IconButton(
                      tooltip: 'Volume',
                      onPressed: () => showVolumeSheet(context, service),
                      icon: Icon(speakerIcon(service.speakerVolume)),
                    ),
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

  /// Video takes the main area while anyone's camera is on.
  bool get _showVideo => service.videoPeers.isNotEmpty || _video.on;

  Widget _wideBody() {
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: PeerList(service: service, onAddPeer: _addPeerDialog),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([service, _video]),
            builder: (context, _) {
              final panel = IntercomPanel(
                service: service,
                video: _video,
                onMessage: _showMessage,
                showParticipants: !_showVideo,
              );
              if (!_showVideo) return Center(child: panel);
              return Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: VideoStage(service: service, video: _video),
                    ),
                  ),
                  panel,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    return ListenableBuilder(
      listenable: Listenable.merge([service, _video]),
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: _showVideo
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: VideoStage(service: service, video: _video),
                  )
                : PeerList(service: service, onAddPeer: _addPeerDialog),
          ),
          if (!_showVideo) const Divider(height: 1),
          SafeArea(
            top: false,
            child: IntercomPanel(
              service: service,
              video: _video,
              onMessage: _showMessage,
              compact: true,
              showParticipants: !_showVideo,
            ),
          ),
        ],
      ),
    );
  }
}
