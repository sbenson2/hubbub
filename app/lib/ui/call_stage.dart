import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../room_adapter.dart';
import 'channel_sidebar.dart';
import 'participant_tile.dart';
import 'theme.dart';
import 'user_panel.dart';
import 'video_view.dart';

/// One tile on the stage: a person (their camera or avatar) or a screen share.
class StageItem {
  const StageItem(this.member, {required this.stream});
  final VoiceMember member;
  final bool stream;

  String get key => '${stream ? 'stream' : 'user'}:${member.id}';
}

/// A person's tile, then another for their screen share when they are streaming.
List<StageItem> stageItems(List<VoiceMember> people) => [
      for (final m in people) ...[
        StageItem(m, stream: false),
        if (m.share != null) StageItem(m, stream: true),
      ],
    ];

/// What the stage does with its tiles; the call view fills this in.
class StageActions {
  const StageActions({
    required this.watching,
    required this.focusKey,
    required this.onWatch,
    required this.onFocus,
    required this.onClose,
    required this.onFullscreen,
    required this.showStats,
    required this.onToggleStats,
    this.rx,
  });

  /// Whose streams are being watched (member ids).
  final Set<String> watching;

  /// The [StageItem.key] shown large, if any.
  final String? focusKey;
  final void Function(VoiceMember) onWatch;
  final void Function(String key) onFocus;

  /// Closes the focused tile; for a watched stream that also stops receiving it.
  final void Function(StageItem) onClose;
  final void Function(StageItem) onFullscreen;

  /// Whether the stats panel is on, and the latest received sample for it.
  final bool showStats;
  final VoidCallback onToggleStats;
  final VideoRxSample? rx;
}

/// Whether [item] has pictures to show large: a camera, a stream you watch, or your own.
bool _hasVideo(StageItem item, Set<String> watching) {
  final m = item.member;
  if (!item.stream) return m.camera != null;
  return m.share != null && (m.isMe || watching.contains(m.id));
}

/// The call stage: a grid of every tile, or, with one focused, that tile large and the rest
/// in a strip below it.
class CallStage extends StatelessWidget {
  const CallStage({super.key, required this.participants, required this.actions});

  final List<VoiceMember> participants;
  final StageActions actions;

  @override
  Widget build(BuildContext context) {
    final items = stageItems(participants);
    final focus = [
      for (final i in items)
        if (i.key == actions.focusKey && _hasVideo(i, actions.watching)) i
    ].firstOrNull;
    if (focus == null) {
      return _TileGrid(items: items, tileFor: _tile);
    }
    final others = [for (final i in items) if (i != focus) i];
    final watchedStream = focus.stream && !focus.member.isMe;
    return Column(children: [
      Expanded(
        child: KeyedSubtree(
          key: const ValueKey('focused'),
          child: Stack(children: [
            Positioned.fill(child: _tile(focus, large: true)),
            if (watchedStream && actions.showStats)
              Positioned(left: 8, top: 40, child: _StatsPanel(actions.rx)),
            Positioned(
              top: 8,
              right: 8,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (watchedStream) ...[
                  _OverlayButton(
                    tooltip: 'Stream Stats',
                    icon: Icons.bar_chart_rounded,
                    onTap: actions.onToggleStats,
                  ),
                  const SizedBox(width: 8),
                ],
                _OverlayButton(
                  tooltip: 'Full Screen',
                  icon: Icons.fullscreen_rounded,
                  onTap: () => actions.onFullscreen(focus),
                ),
                const SizedBox(width: 8),
                _OverlayButton(
                  tooltip: focus.stream && !focus.member.isMe ? 'Stop Watching' : 'Close',
                  icon: Icons.close_rounded,
                  onTap: () => actions.onClose(focus),
                ),
              ]),
            ),
          ]),
        ),
      ),
      if (others.isNotEmpty) ...[
        const SizedBox(height: 8),
        SizedBox(
          key: const ValueKey('strip'),
          height: 120,
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final i in others) ...[
                  SizedBox(width: 120 * 16 / 9, height: 120, child: _tile(i)),
                  if (i != others.last) const SizedBox(width: 8),
                ],
              ]),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _tile(StageItem item, {bool large = false}) {
    final m = item.member;
    final tappable = !large && _hasVideo(item, actions.watching);
    final tile = item.stream
        ? StreamTile(
            member: m,
            watching: actions.watching.contains(m.id),
            onWatch: () => actions.onWatch(m),
          )
        : ParticipantTile(member: m);
    if (!tappable) return tile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => actions.onFocus(item.key), child: tile),
    );
  }
}

/// The received resolution, frame rate and bitrate of the stream on screen.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel(this.rx);

  final VideoRxSample? rx;

  @override
  Widget build(BuildContext context) {
    final r = rx;
    final lines = r == null
        ? const ['Waiting for video…']
        : [
            '${r.width ?? 0}x${r.height ?? 0}',
            '${(r.framesPerSecond ?? 0).round()} fps',
            '${(r.kbps ?? 0).round()} kbps',
          ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final l in lines)
          Text(l,
              style: const TextStyle(
                  fontFamily: hubFont, fontSize: 12, height: 1.3, color: HubColors.white)),
      ]),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.tooltip, required this.icon, required this.onTap});

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(color: Color(0xB3000000), shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: HubColors.white),
            ),
          ),
        ),
      );
}

/// A screen share: yours as a preview, or someone else's with a Watch Stream button until you
/// click it (nothing is received before that).
class StreamTile extends StatelessWidget {
  StreamTile({required this.member, required this.watching, required this.onWatch})
      : super(key: ValueKey('stream:${member.id}'));

  final VoiceMember member;
  final bool watching;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final showVideo = m.share != null && (m.isMe || watching);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: HubColors.tile,
        child: Stack(children: [
          if (showVideo)
            Positioned.fill(child: VideoView(feed: m.share!, contain: true))
          else
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.screen_share_rounded, size: 32, color: HubColors.interactive),
                const SizedBox(height: 8),
                IntrinsicWidth(child: HubButton(label: 'Watch Stream', onPressed: onWatch)),
              ]),
            ),
          const Positioned(left: 8, top: 8, child: _LiveBadge()),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
              child: Text(
                m.isMe ? 'Your stream' : "${m.name}'s stream",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: hubFont,
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  color: HubColors.white,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: HubColors.red, borderRadius: BorderRadius.circular(4)),
        child: const Text('LIVE',
            style: TextStyle(
              fontFamily: hubFont,
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: HubColors.white,
            )),
      );
}

/// Lays tiles out 16:9 at the largest size that fits, rows centred.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.items, required this.tileFor});

  final List<StageItem> items;
  final Widget Function(StageItem) tileFor;

  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final n = items.length;
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
      Widget tile(StageItem i) => SizedBox(width: width, height: height, child: tileFor(i));
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < n; r += columns) ...[
            if (r > 0) const SizedBox(height: _gap),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = r; i < math.min(n, r + columns); i++) ...[
                if (i > r) const SizedBox(width: _gap),
                tile(items[i]),
              ],
            ]),
          ],
        ]),
      );
    });
  }
}
