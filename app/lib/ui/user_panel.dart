import 'package:flutter/material.dart';

import '../audio_settings.dart';
import '../device_settings.dart';
import 'audio_menus.dart';
import 'avatar.dart';
import 'theme.dart';

/// The bottom of the channel column: who you are, and your mic, deafen and settings.
class UserPanel extends StatelessWidget {
  const UserPanel({
    super.key,
    required this.id,
    required this.name,
    required this.tag,
    required this.muted,
    required this.deafened,
    required this.onToggleMute,
    required this.onToggleDeafen,
    required this.onSettings,
    this.devices,
    this.audio,
    this.onVoiceSettings,
  });

  final String id;
  final String name;
  final String tag;
  final bool muted;
  final bool deafened;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleDeafen;
  final VoidCallback onSettings;

  /// With these, a right click on the mic or the headphones opens Discord's device menu.
  final DeviceSettings? devices;
  final AudioSettings? audio;
  final VoidCallback? onVoiceSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: HubColors.panel,
      padding: const EdgeInsets.only(left: 8, right: 8),
      child: Row(children: [
        Avatar(id: id, name: name, size: 32, presence: Presence.online, background: HubColors.panel),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: hubFont,
                    fontSize: 14,
                    height: 1.286,
                    fontWeight: FontWeight.w600,
                    color: HubColors.header,
                  )),
              Text(tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: hubFont,
                    fontSize: 12,
                    height: 1.333,
                    color: HubColors.interactive,
                  )),
            ],
          ),
        ),
        PanelButton(
          tooltip: muted ? 'Unmute' : 'Mute',
          onPressed: onToggleMute,
          onSecondaryTap: devices == null || onVoiceSettings == null
              ? null
              : (at) => showMicMenu(context, at,
                  devices: devices!, audio: audio, onVoiceSettings: onVoiceSettings!),
          child: muted
              ? const CrossedIcon(Icons.mic_rounded,
                  size: 20,
                  color: HubColors.interactive,
                  strike: HubColors.red,
                  background: HubColors.panel)
              : const Icon(Icons.mic_rounded, size: 20),
        ),
        PanelButton(
          tooltip: deafened ? 'Undeafen' : 'Deafen',
          onPressed: onToggleDeafen,
          onSecondaryTap: devices == null || audio == null || onVoiceSettings == null
              ? null
              : (at) => showHeadphonesMenu(context, at,
                  devices: devices!, audio: audio!, onVoiceSettings: onVoiceSettings!),
          child: deafened
              ? const CrossedIcon(Icons.headphones_rounded,
                  size: 20,
                  color: HubColors.interactive,
                  strike: HubColors.red,
                  background: HubColors.panel)
              : const Icon(Icons.headphones_rounded, size: 20),
        ),
        PanelButton(
          tooltip: 'User Settings',
          onPressed: onSettings,
          child: const Icon(Icons.settings_rounded, size: 20),
        ),
      ]),
    );
  }
}

/// A 32 px square icon button with Discord's flat hover fill.
class PanelButton extends StatefulWidget {
  const PanelButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.size = 32,
    this.onSecondaryTap,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;
  final double size;

  /// A right click, with where it happened (for a context menu).
  final void Function(Offset at)? onSecondaryTap;

  @override
  State<PanelButton> createState() => _PanelButtonState();
}

class _PanelButtonState extends State<PanelButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            onSecondaryTapUp: widget.onSecondaryTap == null
                ? null
                : (d) => widget.onSecondaryTap!(d.globalPosition),
            child: Container(
              width: widget.size,
              height: widget.size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? HubColors.selected : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: _hover ? HubColors.text : HubColors.interactive),
                child: widget.child,
              ),
            ),
          ),
        ),
      );
}

/// Shown above the user panel while in a call: where you are, and how to leave.
class VoiceConnectedBar extends StatelessWidget {
  const VoiceConnectedBar({
    super.key,
    required this.channel,
    required this.community,
    required this.onDisconnect,
  });

  final String channel;
  final String community;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => Container(
        color: HubColors.panel,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.signal_cellular_alt_rounded, size: 16, color: HubColors.green),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text('Voice Connected',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: hubFont,
                            fontSize: 14,
                            height: 1.286,
                            fontWeight: FontWeight.w700,
                            color: HubColors.green,
                          )),
                    ),
                  ]),
                  Text('$channel / $community',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: hubFont,
                        fontSize: 12,
                        height: 1.5,
                        color: HubColors.muted,
                      )),
                ],
              ),
            ),
            PanelButton(
              tooltip: 'Disconnect',
              onPressed: onDisconnect,
              child: const Icon(Icons.call_end_rounded, size: 20),
            ),
          ]),
          const SizedBox(height: 8),
          const Divider(height: 1, thickness: 1, color: HubColors.divider),
        ]),
      );
}

/// Discord's filled button: a flat rounded rectangle, brighter on hover.
class HubButton extends StatefulWidget {
  const HubButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = HubColors.accent,
    this.hoverColor = const Color(0xFF4752C4),
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color hoverColor;

  @override
  State<HubButton> createState() => _HubButtonState();
}

class _HubButtonState extends State<HubButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.onPressed == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Opacity(
            opacity: widget.onPressed == null ? 0.5 : 1,
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover && widget.onPressed != null ? widget.hoverColor : widget.color,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(widget.label,
                  style: const TextStyle(
                    fontFamily: hubFont,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: HubColors.white,
                  )),
            ),
          ),
        ),
      );
}
