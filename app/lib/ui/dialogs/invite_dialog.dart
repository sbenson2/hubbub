import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../hub_controller.dart';
import '../theme.dart';
import '../user_panel.dart';
import 'dialog_shell.dart';

/// How long an invite lasts, in minutes; 0 is never.
const expiryChoices = <(String, int)>[
  ('30 minutes', 30),
  ('1 hour', 60),
  ('1 day', 1440),
  ('7 days', 10080),
  ('Never', 0),
];

/// How many people may use an invite; 0 is no limit.
const useChoices = <(String, int)>[
  ('No limit', 0),
  ('1 use', 1),
  ('5 uses', 5),
  ('10 uses', 10),
];

/// Invite People: the link with Copy, a QR code, and Edit invite link (expiry, max uses
/// and Revoke link). Starts with Discord's default of 7 days and no use limit.
Future<void> showInviteDialog(BuildContext context, HubController hub,
        {required String cid, required String serverName}) =>
    showHubDialog<void>(
      context,
      builder: (_) => _InviteDialog(hub: hub, cid: cid, serverName: serverName),
    );

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.hub, required this.cid, required this.serverName});

  final HubController hub;
  final String cid;
  final String serverName;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  int _expiresMin = 10080;
  int _maxUses = 0;
  // The editor's selection; it becomes the applied limits only when a link is made.
  int _pendingExpiresMin = 10080;
  int _pendingMaxUses = 0;
  String? _link;
  String? _error;
  bool _copied = false;
  bool _qr = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _make();
  }

  Future<void> _make() async {
    setState(() {
      _expiresMin = _pendingExpiresMin;
      _maxUses = _pendingMaxUses;
      _link = null;
      _error = null;
      _copied = false;
    });
    try {
      final link = await widget.hub
          .inviteCreate(widget.cid, expiresMin: _expiresMin, maxUses: _maxUses);
      if (mounted) setState(() => _link = link);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not make an invite: $e');
    }
  }

  Future<void> _revoke() async {
    final link = _link;
    if (link == null) return;
    try {
      await widget.hub.inviteRevoke(widget.cid, link);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not revoke the link: $e');
      return;
    }
    await _make();
  }

  Future<void> _copy() async {
    final link = _link;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) setState(() => _copied = true);
  }

  String get _footnote {
    final expiry = _expiresMin == 0
        ? 'never expires'
        : 'expires in ${expiryChoices.firstWhere((c) => c.$2 == _expiresMin).$1}';
    final uses = _maxUses == 0
        ? ''
        : ', ${useChoices.firstWhere((c) => c.$2 == _maxUses).$1} at most';
    return 'Your invite link $expiry$uses.';
  }

  @override
  Widget build(BuildContext context) => HubDialogCard(
        title: 'Invite people to ${widget.serverName}',
        subtitle: 'Send this link to a friend so they can join your server.',
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const HubFieldLabel('SEND A SERVER INVITE LINK TO A FRIEND'),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: BoxDecoration(
              color: HubColors.rail,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(children: [
              Expanded(
                child: SelectableText(_link ?? 'Making your invite…',
                    maxLines: 1,
                    style: HubText.message.copyWith(color: HubColors.text)),
              ),
              const SizedBox(width: 8),
              HubButton(
                label: _copied ? 'Copied' : 'Copy',
                color: _copied ? HubColors.green : HubColors.accent,
                hoverColor: _copied ? const Color(0xFF1A7F44) : const Color(0xFF4752C4),
                onPressed: _link == null ? null : _copy,
              ),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: HubText.small.copyWith(color: HubColors.red)),
          ],
          const SizedBox(height: 8),
          Text(_footnote, style: HubText.small),
          if (_qr && _link != null) ...[
            const SizedBox(height: 16),
            Center(
              child: Container(
                color: HubColors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: _link!, size: 180, key: const ValueKey('invite-qr')),
              ),
            ),
          ],
          if (_editing) ...[
            const SizedBox(height: 16),
            _editor(),
          ],
        ]),
        footer: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            HubLinkButton(_qr ? 'Hide QR code' : 'Show QR code', () => setState(() => _qr = !_qr)),
            HubLinkButton(_editing ? 'Done editing' : 'Edit invite link',
                () => setState(() => _editing = !_editing)),
            HubLinkButton('Close', () => Navigator.of(context).pop()),
          ],
        ),
      );

  Widget _editor() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const HubFieldLabel('EXPIRE AFTER'),
        _Choice(
          key: const ValueKey('expiry'),
          value: _pendingExpiresMin,
          choices: expiryChoices,
          onChanged: (v) => setState(() => _pendingExpiresMin = v),
        ),
        const SizedBox(height: 12),
        const HubFieldLabel('MAX NUMBER OF USES'),
        _Choice(
          key: const ValueKey('uses'),
          value: _pendingMaxUses,
          choices: useChoices,
          onChanged: (v) => setState(() => _pendingMaxUses = v),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          HubButton(label: 'Generate a New Link', onPressed: _make),
          HubButton(
            label: 'Revoke link',
            color: HubColors.red,
            hoverColor: const Color(0xFFA12828),
            onPressed: _link == null ? null : _revoke,
          ),
        ]),
      ]);
}

class _Choice extends StatelessWidget {
  const _Choice(
      {super.key, required this.value, required this.choices, required this.onChanged});

  final int value;
  final List<(String, int)> choices;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: HubColors.rail,
          borderRadius: BorderRadius.circular(3),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: value,
            isExpanded: true,
            dropdownColor: HubColors.rail,
            style: HubText.message.copyWith(color: HubColors.text),
            items: [
              for (final (label, v) in choices) DropdownMenuItem(value: v, child: Text(label)),
            ],
            onChanged: (v) => v == null ? null : onChanged(v),
          ),
        ),
      );
}
