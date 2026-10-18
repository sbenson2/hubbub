import 'package:flutter/material.dart';

import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';

/// Leave Server's confirmation. Local only: the server carries on for everyone else.
/// Returns true when the person confirms.
Future<bool> confirmLeaveServer(BuildContext context, String serverName) async =>
    await showHubDialog<bool>(
      context,
      builder: (context) => HubDialogCard(
        title: 'Leave $serverName',
        body: Text(
            'Are you sure you want to leave $serverName? You can rejoin later with a new invite.',
            style: HubText.message.copyWith(color: HubColors.interactive)),
        footer: Row(children: [
          const Spacer(),
          HubLinkButton('Cancel', () => Navigator.of(context).pop(false)),
          const SizedBox(width: 8),
          HubButton(
            label: 'Leave Server',
            color: HubColors.red,
            hoverColor: const Color(0xFFA12828),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ]),
      ),
    ) ??
    false;
