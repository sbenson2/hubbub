import 'package:flutter/material.dart';

import '../../hub_controller.dart';
import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';
import 'join_dialog.dart';

/// The rail's "+": Create My Own, or (at the bottom) Join a Server. Creating selects the
/// new server.
Future<void> showCreateServerDialog(BuildContext context, HubController hub) =>
    showHubDialog<void>(context, builder: (_) => _CreateDialog(hub: hub, parent: context));

class _CreateDialog extends StatefulWidget {
  const _CreateDialog({required this.hub, required this.parent});

  final HubController hub;

  /// The context under the dialog, used to open the Join dialog after this one closes.
  final BuildContext parent;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  late final _field = TextEditingController(text: "${widget.hub.profileName}'s server");
  bool _naming = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _field.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.hub.create(name);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not create the server: $e';
        });
      }
    }
  }

  void _join() {
    final parent = widget.parent;
    Navigator.of(context).pop();
    if (parent.mounted) showJoinDialog(parent, widget.hub);
  }

  @override
  Widget build(BuildContext context) {
    if (_naming) {
      return HubDialogCard(
        title: 'Customize Your Server',
        subtitle:
            'Give your new server a personality with a name. You can always change it later.',
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const HubFieldLabel('SERVER NAME'),
          TextField(
            controller: _field,
            autofocus: true,
            style: HubText.message.copyWith(color: HubColors.text),
            decoration: hubFieldDecoration(),
            onSubmitted: (_) => _create(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: HubText.small.copyWith(color: HubColors.red)),
          ],
        ]),
        footer: Row(children: [
          HubLinkButton('Back', _busy ? null : () => setState(() => _naming = false)),
          const Spacer(),
          ListenableBuilder(
            listenable: _field,
            builder: (context, _) => HubButton(
              label: 'Create',
              onPressed: _busy || _field.text.trim().isEmpty ? null : _create,
            ),
          ),
        ]),
      );
    }
    return HubDialogCard(
      title: 'Create a server',
      subtitle:
          'Your server is where you and your friends hang out. Make yours and start talking.',
      body: _OptionRow(
        label: 'Create My Own',
        icon: Icons.add_home_rounded,
        onTap: () => setState(() => _naming = true),
      ),
      footer: Column(children: [
        const Text('Have an invite already?',
            style: TextStyle(
                fontFamily: hubFont,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: HubColors.header)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: HubButton(
            label: 'Join a Server',
            color: HubColors.tertiary,
            hoverColor: HubColors.selected,
            onPressed: _join,
          ),
        ),
      ]),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: HubColors.divider),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(icon, size: 36, color: HubColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontFamily: hubFont,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: HubColors.header)),
            ),
            const Icon(Icons.chevron_right_rounded, color: HubColors.interactive),
          ]),
        ),
      );
}
