import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio_diagnostics.dart' show openFolder;
import '../audio_settings.dart';
import '../capture_options.dart';
import '../device_settings.dart';
import '../install.dart';
import '../room_adapter.dart';
import 'context_menu.dart';
import 'mic_meter.dart';
import 'theme.dart';

/// Discord's User Settings, as a wide dialog: sections on the left, the open one on the right.
Future<void> showSettingsDialog(
  BuildContext context, {
  required String memberId,
  required String tag,
  required DeviceSettings devices,
  required AudioSettings audio,
  required ValueListenable<bool> inCall,
  WindowsSettings? windows,
  bool voice = false,
}) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xD9000000),
      builder: (context) => _SettingsDialog(
          memberId: memberId, tag: tag, devices: devices, audio: audio, inCall: inCall, windows: windows, voice: voice),
    );

enum _Section { account, voice, windows }

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.memberId,
    required this.tag,
    required this.devices,
    required this.audio,
    required this.inCall,
    required this.windows,
    required this.voice,
  });

  final String memberId;
  final String tag;
  final DeviceSettings devices;
  final AudioSettings audio;
  final ValueListenable<bool> inCall;

  /// The Windows switches; the section is absent when null.
  final WindowsSettings? windows;
  final bool voice;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late _Section _section = widget.voice ? _Section.voice : _Section.account;

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
                if (widget.windows != null)
                  _NavItem('Windows Settings', _section == _Section.windows,
                      () => setState(() => _section = _Section.windows)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 60, 40, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      switch (_section) {
                        _Section.account => 'My Account',
                        _Section.voice => 'Voice & Video',
                        _Section.windows => 'Windows Settings',
                      },
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
                      child: switch (_section) {
                        _Section.account => _Account(memberId: widget.memberId, tag: widget.tag),
                        _Section.voice => _VoiceVideo(
                            devices: widget.devices, audio: widget.audio, inCall: widget.inCall),
                        _Section.windows => _WindowsSection(settings: widget.windows!),
                      },
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

/// Start at login (on by default after an install, like Discord) and the installed version.
class _WindowsSection extends StatefulWidget {
  const _WindowsSection({required this.settings});
  final WindowsSettings settings;

  @override
  State<_WindowsSection> createState() => _WindowsSectionState();
}

class _WindowsSectionState extends State<_WindowsSection> {
  late bool _login = widget.settings.startAtLogin;

  @override
  Widget build(BuildContext context) {
    final version = widget.settings.version;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('SYSTEM', style: HubText.category),
      const SizedBox(height: 8),
      SwitchListTile(
        key: const Key('start-at-login'),
        contentPadding: EdgeInsets.zero,
        activeThumbColor: HubColors.accent,
        title: const Text('Open Hubbub', style: HubText.message),
        subtitle: const Text('Start Hubbub in the tray when you log in to Windows, so your servers stay online.',
            style: TextStyle(fontFamily: hubFont, fontSize: 14, height: 1.3, color: HubColors.muted)),
        value: _login,
        onChanged: (on) {
          try {
            widget.settings.setStartAtLogin(on);
          } catch (e) {
            debugPrint('hubbub: could not change start at login: $e');
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Could not change that setting.')));
          }
          // Read the real state back, which also puts the switch back after a failure.
          setState(() => _login = widget.settings.startAtLogin);
        },
      ),
      const SizedBox(height: 24),
      const Text('VERSION', style: HubText.category),
      const SizedBox(height: 8),
      Text(version == null ? 'Not installed (running from a build folder)' : 'Hubbub $version',
          key: const Key('app-version'), style: HubText.message),
    ]);
  }
}

/// Input and output side by side, the camera below.
class _VoiceVideo extends StatelessWidget {
  const _VoiceVideo({required this.devices, required this.audio, required this.inCall});
  final DeviceSettings devices;
  final AudioSettings audio;
  final ValueListenable<bool> inCall;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([devices, audio]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _DevicePicker('INPUT DEVICE', const Key('device-input'), devices,
                      DeviceKind.audioInput),
                  const SizedBox(height: 16),
                  Row(children: [
                    const Expanded(child: Text('INPUT VOLUME', style: HubText.category)),
                    Text(percent(audio.inputGain), style: HubText.category),
                  ]),
                  VolumeSlider(
                    key: const Key('settings-input-volume'),
                    value: audio.inputGain,
                    onChanged: audio.setInputGain,
                    onChangeEnd: audio.commit,
                  ),
                  const SizedBox(height: 8),
                  const Text('INPUT LEVEL', style: HubText.category),
                  const SizedBox(height: 8),
                  MicMeter(levels: audio.micLevels, inCall: inCall),
                ]),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _DevicePicker('OUTPUT DEVICE', const Key('device-output'), devices,
                      DeviceKind.audioOutput),
                  const SizedBox(height: 16),
                  Row(children: [
                    const Expanded(child: Text('OUTPUT VOLUME', style: HubText.category)),
                    Text(percent(audio.master), style: HubText.category),
                  ]),
                  VolumeSlider(
                    key: const Key('settings-output-volume'),
                    value: audio.master,
                    onChanged: audio.setMaster,
                    onChangeEnd: audio.commit,
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 24),
            const Text('NOISE SUPPRESSION', style: HubText.category),
            const SizedBox(height: 8),
            for (final n in NoiseSuppression.values)
              _NoiseChoice(n, audio.noiseSuppression == n, () => audio.setNoiseSuppression(n)),
            const SizedBox(height: 24),
            _DevicePicker('CAMERA', const Key('device-camera'), devices, DeviceKind.videoInput),
            if (defaultTargetPlatform == TargetPlatform.windows)
              SwitchListTile(
                key: const Key('low-light-full-frame-rate'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: HubColors.accent,
                title: const Text('Keep full frame rate in low light', style: HubText.message),
                subtitle: const Text('Stops the webcam slowing down in dim light. The picture may be darker.',
                    style: TextStyle(fontFamily: hubFont, fontSize: 14, height: 1.3, color: HubColors.muted)),
                value: audio.lowLightFullFrameRate,
                onChanged: audio.setLowLightFullFrameRate,
              ),
            if (audio.diagnosticsSupported) ...[
              const SizedBox(height: 24),
              const Text('ADVANCED', style: HubText.category),
              SwitchListTile(
                key: const Key('record-diagnostics'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: HubColors.red,
                title: const Text('Record call audio for diagnostics (saves to a folder)',
                    style: HubText.message),
                subtitle: const Text(
                    'Saves what you send and what you hear, as WAV files on this PC only, to find out why '
                    'a voice sounds muffled or cut off. A red "Recording audio" badge shows while it is on. '
                    'It switches itself off when Hubbub restarts.',
                    style: TextStyle(fontFamily: hubFont, fontSize: 14, height: 1.3, color: HubColors.muted)),
                value: audio.recordDiagnostics,
                onChanged: audio.setRecordDiagnostics,
              ),
              if (audio.diagnosticsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'The recording may not have stopped: ${audio.diagnosticsError}. '
                      'Switch it off again to retry.',
                      key: const Key('recording-error'),
                      style: const TextStyle(fontFamily: hubFont, fontSize: 13, color: HubColors.red)),
                ),
              if (audio.lastReport != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Expanded(
                      child: SelectableText('Last recording: ${audio.lastReport!.directory}',
                          key: const Key('last-recording'),
                          style: const TextStyle(
                              fontFamily: hubFont, fontSize: 13, color: HubColors.muted)),
                    ),
                    TextButton(
                      key: const Key('last-recording-open'),
                      onPressed: () => openFolder(audio.lastReport!.directory),
                      child: const Text('Open folder'),
                    ),
                  ]),
                ),
            ],
          ],
        ),
      );
}

/// One Noise Suppression choice: a radio, its name, and what it does.
class _NoiseChoice extends StatelessWidget {
  const _NoiseChoice(this.choice, this.selected, this.onTap);
  final NoiseSuppression choice;
  final bool selected;
  final VoidCallback onTap;

  static const _about = {
    NoiseSuppression.none: 'Only echo cancellation. Everything the mic hears is sent.',
    NoiseSuppression.standard: 'WebRTC noise suppression. Good against steady hiss and hum.',
    NoiseSuppression.rnnoise:
        'Neural noise suppression. Also removes keyboard clicks, fans and background voices.',
  };

  @override
  Widget build(BuildContext context) => InkWell(
        key: Key('ns-${choice.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20, color: selected ? HubColors.accent : HubColors.interactive),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(choice.label, style: HubText.message),
                Text(_about[choice]!,
                    style: const TextStyle(
                        fontFamily: hubFont, fontSize: 13, height: 1.3, color: HubColors.muted)),
              ]),
            ),
          ]),
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
