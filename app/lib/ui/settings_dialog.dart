import 'package:flutter/material.dart';

import '../device_settings.dart';
import '../room_adapter.dart';
import 'theme.dart';

/// Discord's User Settings, as a wide dialog: sections on the left, the open one on the right.
Future<void> showSettingsDialog(
  BuildContext context, {
  required String memberId,
  required String tag,
  required DeviceSettings devices,
}) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xD9000000),
      builder: (context) => _SettingsDialog(memberId: memberId, tag: tag, devices: devices),
    );

enum _Section { account, voice }

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.memberId, required this.tag, required this.devices});

  final String memberId;
  final String tag;
  final DeviceSettings devices;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  _Section _section = _Section.account;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: HubColors.main,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880, maxHeight: 640),
          child: Row(children: [
            Container(
              width: 218,
              color: HubColors.sidebar,
              padding: const EdgeInsets.fromLTRB(10, 60, 6, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Text('USER SETTINGS', style: HubText.category),
                ),
                _NavItem('My Account', _section == _Section.account,
                    () => setState(() => _section = _Section.account)),
                _NavItem('Voice & Video', _section == _Section.voice,
                    () => setState(() => _section = _Section.voice)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 60, 40, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_section == _Section.account ? 'My Account' : 'Voice & Video',
                      style: const TextStyle(
                        fontFamily: hubFont,
                        fontSize: 20,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: HubColors.header,
                      )),
                  const SizedBox(height: 20),
                  Expanded(
                    child: SingleChildScrollView(
                      child: _section == _Section.account
                          ? _Account(memberId: widget.memberId, tag: widget.tag)
                          : _VoiceVideo(devices: widget.devices),
                    ),
                  ),
                  Row(children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close',
                          style: TextStyle(fontFamily: hubFont, fontSize: 14, color: HubColors.header)),
                    ),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      );
}

class _NavItem extends StatefulWidget {
  const _NavItem(this.label, this.selected, this.onTap);
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 34,
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: widget.selected
                  ? HubColors.selected
                  : _hover
                      ? HubColors.hover
                      : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(widget.label,
                style: TextStyle(
                  fontFamily: hubFont,
                  fontSize: 16,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: widget.selected || _hover ? HubColors.header : HubColors.interactive,
                )),
          ),
        ),
      );
}

/// Your member id (selectable) and your tag.
class _Account extends StatelessWidget {
  const _Account({required this.memberId, required this.tag});
  final String memberId;
  final String tag;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MEMBER ID', style: HubText.category),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: HubColors.rail,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(memberId,
                style: const TextStyle(
                  fontFamily: hubFont,
                  fontSize: 14,
                  height: 1.4,
                  color: HubColors.text,
                )),
          ),
          const SizedBox(height: 16),
          const Text('TAG', style: HubText.category),
          const SizedBox(height: 8),
          SelectableText(tag, style: HubText.message),
        ],
      );
}

/// Input and output side by side, the camera below.
class _VoiceVideo extends StatelessWidget {
  const _VoiceVideo({required this.devices});
  final DeviceSettings devices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: devices,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: _DevicePicker('INPUT DEVICE', const Key('device-input'), devices,
                      DeviceKind.audioInput)),
              const SizedBox(width: 20),
              Expanded(
                  child: _DevicePicker('OUTPUT DEVICE', const Key('device-output'), devices,
                      DeviceKind.audioOutput)),
            ]),
            const SizedBox(height: 24),
            _DevicePicker('CAMERA', const Key('device-camera'), devices, DeviceKind.videoInput),
          ],
        ),
      );
}

/// A labelled dropdown: "Default" first, then the devices; disabled when there are none.
class _DevicePicker extends StatelessWidget {
  const _DevicePicker(this.title, this.fieldKey, this.devices, this.kind);
  final String title;
  final Key fieldKey;
  final DeviceSettings devices;
  final DeviceKind kind;

  static const _style =
      TextStyle(fontFamily: hubFont, fontSize: 16, height: 1.25, color: HubColors.text);

  @override
  Widget build(BuildContext context) {
    final list = devices.devices(kind);
    final selected = devices.selected(kind);
    final index = selected == null ? -1 : list.indexWhere((d) => d.id == selected.id);
    final empty = list.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: HubText.category),
      const SizedBox(height: 8),
      Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: HubColors.rail,
          borderRadius: BorderRadius.circular(3),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: fieldKey,
            isExpanded: true,
            value: empty ? null : index,
            hint: const Text('No devices found', style: TextStyle(fontFamily: hubFont, fontSize: 16, color: HubColors.muted)),
            dropdownColor: HubColors.rail,
            borderRadius: BorderRadius.circular(4),
            icon: const Icon(Icons.expand_more_rounded, color: HubColors.interactive),
            style: _style,
            items: empty
                ? null
                : [
                    const DropdownMenuItem(value: -1, child: Text('Default', style: _style)),
                    for (var i = 0; i < list.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(devices.labelOf(list[i]),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: _style),
                      ),
                  ],
            onChanged: empty ? null : (i) => devices.choose(kind, i == null || i < 0 ? null : list[i]),
          ),
        ),
      ),
      if (devices.errorOf(kind) != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(devices.errorOf(kind)!,
              key: Key('error-${kind.name}'),
              style: const TextStyle(
                  fontFamily: hubFont, fontSize: 12, height: 1.33, color: HubColors.red)),
        ),
    ]);
  }
}
