import 'package:flutter/material.dart';

import '../audio_settings.dart';
import '../device_settings.dart';
import '../room_adapter.dart';
import 'context_menu.dart';
import 'theme.dart';

/// Gives the call stage, sidebar and member list the output levels, so a right click on a
/// person can open their volume menu. Without a scope those widgets have no such menu.
class AudioScope extends InheritedNotifier<AudioSettings> {
  const AudioScope({super.key, required AudioSettings audio, required super.child})
      : super(notifier: audio);

  static AudioSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AudioScope>()?.notifier;
}

/// Right click on the mic: the input device, then Voice Settings.
Future<void> showMicMenu(BuildContext context, Offset at,
        {required DeviceSettings devices, required VoidCallback onVoiceSettings}) =>
    showHubMenu(context, at, (menu) => _DeviceMenu(
          kind: DeviceKind.audioInput,
          title: 'INPUT DEVICE',
          devices: devices,
          onVoiceSettings: onVoiceSettings,
        ));

/// Right click on the headphones: the output device, the master output volume, Voice Settings.
Future<void> showHeadphonesMenu(BuildContext context, Offset at,
        {required DeviceSettings devices,
        required AudioSettings audio,
        required VoidCallback onVoiceSettings}) =>
    showHubMenu(context, at, (menu) => _DeviceMenu(
          kind: DeviceKind.audioOutput,
          title: 'OUTPUT DEVICE',
          devices: devices,
          audio: audio,
          onVoiceSettings: onVoiceSettings,
        ));

class _DeviceMenu extends StatelessWidget {
  const _DeviceMenu({
    required this.kind,
    required this.title,
    required this.devices,
    required this.onVoiceSettings,
    this.audio,
  });
  final DeviceKind kind;
  final String title;
  final DeviceSettings devices;
  final AudioSettings? audio;
  final VoidCallback onVoiceSettings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([devices, ?audio]),
        builder: (context, _) {
          final list = devices.devices(kind);
          final selected = devices.selected(kind);
          IconData radio(bool on) =>
              on ? Icons.radio_button_checked : Icons.radio_button_unchecked;
          // The same call as the settings dropdown: one code path, with its live switch and
          // its revert on failure. The menu closes first; a failure shows in settings.
          void choose(MediaDeviceInfo? d) {
            Navigator.of(context).pop();
            devices.choose(kind, d);
          }

          return Column(mainAxisSize: MainAxisSize.min, children: [
            MenuLabel(title),
            MenuItem(
                key: const Key('menu-item:Default'),
                label: 'Default',
                leading: radio(selected == null),
                onTap: () => choose(null)),
            for (final d in list)
              MenuItem(
                  key: Key('menu-item:${devices.labelOf(d)}'),
                  label: devices.labelOf(d),
                  leading: radio(selected?.id == d.id),
                  onTap: () => choose(d)),
            if (audio != null) ...[
              const _Divider(),
              MenuLabel('OUTPUT VOLUME', trailing: percent(audio!.master)),
              VolumeSlider(
                key: const Key('menu-output-volume'),
                value: audio!.master,
                onChanged: audio!.setMaster,
                onChangeEnd: audio!.commit,
              ),
            ],
            const _Divider(),
            MenuItem(
                label: 'Voice Settings',
                onTap: () {
                  Navigator.of(context).pop();
                  onVoiceSettings();
                }),
          ]);
        },
      );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, thickness: 1, color: HubColors.divider),
      );
}

/// Right click on [child] opens that person's volume menu (volume, and a local mute); you get
/// none for yourself, and without an [AudioScope] there is none at all.
class UserVolumeRegion extends StatelessWidget {
  const UserVolumeRegion({
    super.key,
    required this.id,
    required this.name,
    required this.isMe,
    required this.child,
  });
  final String id;
  final String name;
  final bool isMe;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final audio = AudioScope.maybeOf(context);
    if (audio == null || isMe) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => showHubMenu(
          context, d.globalPosition, (menu) => _UserMenu(id: id, name: name, audio: audio)),
      child: child,
    );
  }
}

class _UserMenu extends StatelessWidget {
  const _UserMenu({required this.id, required this.name, required this.audio});
  final String id;
  final String name;
  final AudioSettings audio;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: audio,
        builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: HubText.title),
            ),
          ),
          MenuLabel('User Volume', trailing: percent(audio.volumeOf(id))),
          VolumeSlider(
            key: const Key('user-volume'),
            value: audio.volumeOf(id),
            onChanged: (v) => audio.setVolume(id, v),
            onChangeEnd: audio.commit,
          ),
          const _Divider(),
          MenuItem(
            label: 'Mute',
            leading: audio.isLocallyMuted(id)
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            onTap: () {
              Navigator.of(context).pop();
              audio.setLocalMute(id, !audio.isLocallyMuted(id));
            },
          ),
        ]),
      );
}
