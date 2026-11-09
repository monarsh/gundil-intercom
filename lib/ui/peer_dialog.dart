import 'package:flutter/material.dart';

import '../src/protocol.dart';

/// Result of the add/edit peer dialog.
class PeerFormResult {
  PeerFormResult({required this.label, required this.host, required this.port});
  final String label;
  final String host;
  final int port;
}

/// Dialog for adding a peer by IP or editing a saved one.
///
/// [hostEditable] is false when giving a discovered peer a custom name (its
/// address is known and managed automatically).
Future<PeerFormResult?> showPeerDialog(
  BuildContext context, {
  required String title,
  String label = '',
  String host = '',
  int port = defaultTcpPort,
  String? nameHint,
  bool hostEditable = true,
  String confirmText = 'Save',
}) {
  return showDialog<PeerFormResult>(
    context: context,
    builder: (_) => _PeerDialog(
      title: title,
      label: label,
      host: host,
      port: port,
      nameHint: nameHint,
      hostEditable: hostEditable,
      confirmText: confirmText,
    ),
  );
}

class _PeerDialog extends StatefulWidget {
  const _PeerDialog({
    required this.title,
    required this.label,
    required this.host,
    required this.port,
    required this.nameHint,
    required this.hostEditable,
    required this.confirmText,
  });

  final String title;
  final String label;
  final String host;
  final int port;
  final String? nameHint;
  final bool hostEditable;
  final String confirmText;

  @override
  State<_PeerDialog> createState() => _PeerDialogState();
}

class _PeerDialogState extends State<_PeerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label = TextEditingController(
    text: widget.label,
  );
  late final TextEditingController _host = TextEditingController(
    text: widget.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.port}',
  );

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      PeerFormResult(
        label: _label.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _label,
                autofocus: !widget.hostEditable || widget.host.isNotEmpty,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: widget.nameHint ?? 'e.g. Reception',
                  helperText: 'Optional',
                  border: const OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _host,
                      enabled: widget.hostEditable,
                      autofocus: widget.hostEditable && widget.host.isEmpty,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'IP address or host',
                        hintText: '192.168.1.42',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return 'Required';
                        if (t.contains(' ')) return 'No spaces';
                        return null;
                      },
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 96,
                    child: TextFormField(
                      controller: _port,
                      enabled: widget.hostEditable,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final p = int.tryParse(v?.trim() ?? '');
                        if (p == null || p < 1 || p > 65535) return '1–65535';
                        return null;
                      },
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmText)),
      ],
    );
  }
}
