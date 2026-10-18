import 'dart:async';

import 'package:flutter/material.dart';

import '../../hub_api.dart';
import '../../hub_controller.dart';
import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';

/// Join a Server: paste an invite, see the server's name, press Join, and watch the
/// progress. A [link] given up front (a clipboard or clicked invite) skips the paste step.
Future<void> showJoinDialog(BuildContext context, HubController hub, {String? link}) =>
    showHubDialog<void>(context, dismissible: false, builder: (_) => _JoinDialog(hub: hub, link: link));

class _JoinDialog extends StatefulWidget {
  const _JoinDialog({required this.hub, this.link});

  final HubController hub;
  final String? link;

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  late final _field = TextEditingController(text: widget.link ?? '');
  StreamSubscription<JoinEvent>? _sub;
  JoinEvent? _state;
  bool _started = false;

  AppInvitePreview? get _preview {
    final text = _field.text.trim();
    return text.isEmpty ? null : widget.hub.inviteParse(text);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _join() {
    setState(() {
      _started = true;
      _state = const JoinTrying();
    });
    _sub = widget.hub.join(_field.text.trim()).listen((e) {
      if (!mounted) return;
      if (e is JoinJoined) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _state = e);
    }, onError: (Object e) {
      if (mounted) setState(() => _state = JoinDenied('$e'));
    });
  }

  Future<void> _cancel() async {
    final stop = _started && _state is! JoinDenied;
    Navigator.of(context).pop();
    if (stop) await widget.hub.joinCancel();
  }

  void _back() {
    _sub?.cancel();
    setState(() {
      _started = false;
      _state = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (_started) return _progress(preview?.name ?? 'the server');
    return HubDialogCard(
      title: 'Join a Server',
      subtitle: 'Enter an invite below to join an existing server.',
      body: ListenableBuilder(
        listenable: _field,
        builder: (context, _) {
          final p = _preview;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const HubFieldLabel('INVITE LINK'),
            TextField(
              controller: _field,
              autofocus: true,
              style: HubText.message.copyWith(color: HubColors.text),
              decoration: hubFieldDecoration(hint: 'hubbub://join/...'),
            ),
            if (_field.text.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              p == null
                  ? Text('That is not a valid invite.',
                      style: HubText.small.copyWith(color: HubColors.red))
                  : _Preview(preview: p),
            ],
          ]);
        },
      ),
      footer: Row(children: [
        HubLinkButton('Cancel', _cancel),
        const Spacer(),
        ListenableBuilder(
          listenable: _field,
          builder: (context, _) =>
              HubButton(label: 'Join', onPressed: _preview == null ? null : _join),
        ),
      ]),
    );
  }

  Widget _progress(String name) {
    final state = _state;
    final denied = state is JoinDenied;
    final String title = denied ? 'Could not join' : 'Joining $name';
    final String message = switch (state) {
      JoinOffline() => 'Nobody from $name is online right now; Hubbub will keep trying.',
      JoinDenied(:final reason) => reason,
      _ => 'Looking for someone from $name…',
    };
    return HubDialogCard(
      title: title,
      body: Row(children: [
        if (!denied)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: HubColors.accent),
            ),
          ),
        Expanded(
          child: Text(message,
              style: HubText.message.copyWith(
                  color: denied ? HubColors.red : HubColors.interactive)),
        ),
      ]),
      footer: Row(children: [
        const Spacer(),
        if (denied) HubLinkButton('Back', _back),
        HubLinkButton(denied ? 'Close' : 'Cancel', _cancel),
      ]),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.preview});

  final AppInvitePreview preview;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: HubColors.sidebar, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          const Icon(Icons.groups_rounded, color: HubColors.interactive),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text("YOU'VE BEEN INVITED TO JOIN", style: HubText.category),
              const SizedBox(height: 2),
              Text(preview.name,
                  style: const TextStyle(
                      fontFamily: hubFont,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: HubColors.header)),
            ]),
          ),
        ]),
      );
}
