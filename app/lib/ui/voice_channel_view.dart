import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar.dart';
import 'channel_sidebar.dart';
import 'participant_tile.dart';
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
    required this.onToggleMute,
    required this.onLeave,
    required this.onJoin,
  });

  final String channel;
  final List<VoiceMember> participants;

  /// Whether we are in this channel's call.
  final bool connected;
  final bool connecting;
  final bool muted;
  final VoidCallback onToggleMute;
  final VoidCallback onLeave;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: HubColors.stage,
      child: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: connected && participants.isNotEmpty
                ? _TileGrid(participants: participants)
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
                    // T10 adds the camera and screen share buttons here.
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

/// Lays tiles out 16:9 at the largest size that fits, rows centred.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.participants});

  final List<VoiceMember> participants;

  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final n = participants.length;
      var best = 0.0;
      var columns = 1;
      for (var c = 1; c <= n; c++) {
        final rows = (n / c).ceil();
        final byWidth = (box.maxWidth - _gap * (c - 1)) / c;
        final byHeight = (box.maxHeight - _gap * (rows - 1)) / rows * 16 / 9;
        final w = math.min(byWidth, byHeight);
        if (w > best) {
          best = w;
          columns = c;
        }
      }
      final width = math.max(0.0, best);
      final height = width * 9 / 16;
      Widget tile(VoiceMember p) =>
          SizedBox(width: width, height: height, child: ParticipantTile(member: p));
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < n; r += columns) ...[
            if (r > 0) const SizedBox(height: _gap),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = r; i < math.min(n, r + columns); i++) ...[
                if (i > r) const SizedBox(width: _gap),
                tile(participants[i]),
              ],
            ]),
          ],
        ]),
      );
    });
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
