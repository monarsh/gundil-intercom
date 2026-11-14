import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import 'widgets.dart';

/// Result of the new/edit group dialog.
class GroupFormResult {
  GroupFormResult(this.name, this.members);
  final String name;

  /// Device ids of the other members (not us).
  final Set<String> members;
}

/// Dialog to create a group or change one: a name and who is in it. Lists
/// every peer we know (online or saved) plus the group's current members.
Future<GroupFormResult?> showGroupDialog(
  BuildContext context, {
  required IntercomService service,
  Group? group,
}) => showDialog<GroupFormResult>(
  context: context,
  builder: (_) => _GroupDialog(service: service, group: group),
);

class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.service, this.group});

  final IntercomService service;
  final Group? group;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.group?.name ?? '',
  );
  late final Set<String> _members = {
    ...?widget.group?.members.keys.where((id) => id != widget.service.selfId),
  };
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// (id, name, platform, online) of everyone that can be picked.
  List<(String, String, String, bool)> get _candidates {
    final s = widget.service;
    final out = <(String, String, String, bool)>[];
    final seen = <String>{};
    for (final e in s.entries) {
      final id = e.peerId;
      if (id == null || !seen.add(id)) continue;
      out.add((id, e.name, e.platform, e.online));
    }
    for (final id in widget.group?.members.keys ?? const <String>[]) {
      if (id == s.selfId || !seen.add(id)) continue;
      out.add((id, s.displayName(id), '?', false));
    }
    return out;
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the group a name');
      return;
    }
    if (_members.isEmpty) {
      setState(() => _error = 'Pick at least one peer');
      return;
    }
    Navigator.pop(context, GroupFormResult(name, _members));
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(widget.group == null ? 'New group' : 'Edit group'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.group == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'e.g. Family, Workshop',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('Members', style: text.labelLarge),
            Text(
              'Everyone in the group hears everyone. Members get the group '
              'on their device too and can call it.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 4),
            if (candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No peers yet. Add or discover peers first.'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (id, name, platform, online) in candidates)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _members.contains(id),
                      onChanged: (v) => setState(() {
                        _error = null;
                        v == true ? _members.add(id) : _members.remove(id);
                      }),
                      secondary: Icon(platformIcon(platform)),
                      title: Text(name),
                      subtitle: Text(online ? 'Online' : 'Offline'),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.group == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
