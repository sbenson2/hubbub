import 'dart:async';

import 'package:flutter/material.dart';

import '../../share_sources.dart';
import '../theme.dart';
import 'dialog_shell.dart';

const portalShareCancelled = 'Screen sharing was cancelled';
const portalShareNoScreen = 'No screen was chosen';
const portalShareMoved = 'Your screen share stopped when the call moved. Choose a screen to share again.';

/// What the wait ended with: the chosen source [id], or neither when the user cancelled in
/// Hubbub, or an [error] (a timeout, or the system share prompt failing).
class PortalPick {
  const PortalPick({this.id, this.error});
  final String? id;
  final Object? error;
}

/// Wayland: the system draws the share prompt (GNOME's own dialog), so Hubbub only waits for
/// it. Shows "Choose a screen in the system dialog" with a Cancel until [load] returns the
/// chosen source. It cannot see a Cancel in the system prompt, so Hubbub's Cancel (and the
/// loader's timeout) is how the wait ends then.
Future<PortalPick> showPortalWait(BuildContext context, PortalScreenSource load) async =>
    await showHubDialog<PortalPick>(context, dismissible: false, builder: (_) => _PortalWait(load: load)) ??
    const PortalPick();

class _PortalWait extends StatefulWidget {
  const _PortalWait({required this.load});

  final PortalScreenSource load;

  @override
  State<_PortalWait> createState() => _PortalWaitState();
}

class _PortalWaitState extends State<_PortalWait> {
  final _cancel = PortalCancel();

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    PortalPick pick;
    try {
      pick = PortalPick(id: await widget.load(_cancel));
    } catch (e) {
      pick = PortalPick(error: e);
    }
    if (mounted && !_cancel.cancelled) Navigator.of(context).pop(pick);
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HubDialogCard(
        title: 'Share Your Screen',
        body: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(
            child: Text('Choose a screen in the system dialog',
                style: HubText.message.copyWith(color: HubColors.interactive)),
          ),
        ]),
        footer: Row(children: [
          const Spacer(),
          HubLinkButton('Cancel', () {
            _cancel.cancel();
            Navigator.of(context).pop(const PortalPick());
          }),
        ]),
      );
}
