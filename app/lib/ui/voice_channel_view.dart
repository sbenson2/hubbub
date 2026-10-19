import 'package:flutter/material.dart';

import 'avatar.dart';
import 'call_stage.dart';
import 'channel_sidebar.dart';
import 'theme.dart';
import 'user_panel.dart';

/// A voice channel's call stage: a grid of participant tiles over a dark stage, with the
/// call controls centred at the bottom.
class VoiceChannelView extends StatelessWidget {
  const VoiceChannelView({
    super.key,
    required this.channel,
    required this.participants,
    required this.connected,
    required this.connecting,
    required this.muted,
    required this.cameraOn,
    required this.sharing,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onToggleShare,
    required this.onLeave,
    required this.onJoin,
    required this.stage,
  });

  final String channel;
  final List<VoiceMember> participants;

  /// Whether we are in this channel's call.
  final bool connected;
  final bool connecting;
  final bool muted;
  final bool cameraOn;
  final bool sharing;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleShare;
  final VoidCallback onLeave;
  final VoidCallback onJoin;
  final StageActions stage;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: HubColors.stage,
      child: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: connected && participants.isNotEmpty
                ? CallStage(participants: participants, actions: stage)
                : _Lobby(channel: channel, connecting: connecting, onJoin: onJoin),
          ),
        ),
        SizedBox(
          height: 88,
          child: connected
              ? Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _CallButton(
                      tooltip: muted ? 'Unmute' : 'Mute',
                      onPressed: onToggleMute,
                      color: muted ? HubColors.white : const Color(0xFF2B2D31),
                      child: muted
                          ? const CrossedIcon(Icons.mic_rounded,
                              size: 24,
                              color: Color(0xFF2B2D31),
                              strike: HubColors.red,
                              background: HubColors.white)
                          : const Icon(Icons.mic_rounded, size: 24, color: HubColors.white),
                    ),
                    const SizedBox(width: 16),
                    _CallButton(
                      tooltip: cameraOn ? 'Turn Off Camera' : 'Turn On Camera',
                      onPressed: onToggleCamera,
                      color: cameraOn ? HubColors.white : const Color(0xFF2B2D31),
                      child: cameraOn
                          ? const Icon(Icons.videocam_rounded, size: 24, color: Color(0xFF2B2D31))
                          : const Icon(Icons.videocam_off_rounded, size: 24, color: HubColors.white),
                    ),
                    const SizedBox(width: 16),
                    _CallButton(
                      tooltip: sharing ? 'Stop Streaming' : 'Share Your Screen',
                      onPressed: onToggleShare,
                      color: sharing ? HubColors.white : const Color(0xFF2B2D31),
                      child: sharing
                          ? const Icon(Icons.stop_screen_share_rounded, size: 24, color: Color(0xFF2B2D31))
                          : const Icon(Icons.screen_share_rounded, size: 24, color: HubColors.white),
                    ),
                    const SizedBox(width: 16),
                    _CallButton(
                      tooltip: 'Disconnect',
                      onPressed: onLeave,
                      color: HubColors.red,
                      child: const Icon(Icons.call_end_rounded, size: 24, color: HubColors.white),
                    ),
                  ]),
                )
              : null,
        ),
      ]),
    );
  }
}

class _Lobby extends StatelessWidget {
  const _Lobby({required this.channel, required this.connecting, required this.onJoin});

  final String channel;
  final bool connecting;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(channel,
              style: const TextStyle(
                fontFamily: hubFont,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: HubColors.header,
              )),
          const SizedBox(height: 8),
          Text(connecting ? 'Connecting…' : 'No one is here yet. Join to start a call.',
              textAlign: TextAlign.center,
              style: HubText.message.copyWith(color: HubColors.interactive)),
          const SizedBox(height: 20),
          if (!connecting)
            HubButton(
              label: 'Join Voice',
              onPressed: onJoin,
              color: HubColors.green,
              hoverColor: const Color(0xFF1A8B4C),
            ),
        ]),
      );
}

class _CallButton extends StatefulWidget {
  const _CallButton({
    required this.tooltip,
    required this.onPressed,
    required this.color,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Color color;
  final Widget child;

  @override
  State<_CallButton> createState() => _CallButtonState();
}

class _CallButtonState extends State<_CallButton> {
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
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? Color.lerp(widget.color, HubColors.white, 0.12) : widget.color,
                shape: BoxShape.circle,
              ),
              child: widget.child,
            ),
          ),
        ),
      );
}
