import 'package:flutter/material.dart';

import '../avatar.dart';
import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';

/// First run: asks what everyone should call you. Returns the name; it cannot be dismissed
/// without one. No email and no password.
Future<String?> showNameDialog(BuildContext context, {String initial = ''}) =>
    showHubDialog<String>(
      context,
      dismissible: false,
      builder: (_) => _NameDialog(initial: initial),
    );

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _field.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => HubDialogCard(
        title: 'What should everyone call you?',
        subtitle: 'Pick a display name. Friends in your servers will see it.',
        body: ListenableBuilder(
          listenable: _field,
          builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Avatar(
                id: 'profile',
                name: _field.text.trim().isEmpty ? '?' : _field.text.trim(),
                size: 80,
                background: HubColors.main,
              ),
            ),
            const SizedBox(height: 16),
            const HubFieldLabel('DISPLAY NAME'),
            TextField(
              controller: _field,
              autofocus: true,
              maxLength: 32,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
              style: HubText.message.copyWith(color: HubColors.text),
              decoration: hubFieldDecoration(),
              onSubmitted: (_) => _submit(),
            ),
          ]),
        ),
        footer: ListenableBuilder(
          listenable: _field,
          builder: (context, _) => Align(
            alignment: Alignment.centerRight,
            child: HubButton(
              label: 'Continue',
              onPressed: _field.text.trim().isEmpty ? null : _submit,
            ),
          ),
        ),
      );
}
