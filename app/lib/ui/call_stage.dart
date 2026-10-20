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
    this.tx = const [],
    this.link,
    this.onHidden,
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

  /// Your own outbound video (screen share and camera) while it is on, shown under the stats.
  final List<VideoTxSample> tx;

  /// The media connection line (`Connection: direct · 42 ms · 0.1% loss`), when there is one.
  final String? link;

  /// Told the [StageItem.key]s of the strip tiles that are scrolled out of view (empty when
  /// none are, or there is no strip), so their video can stop being received.
  final void Function(Set<String> keys)? onHidden;
}

/// Which of [count] tiles of [tileWidth], [gap] apart in a row, are entirely outside the
/// [viewport] wide window scrolled to [offset]. A row that fits has none.
Set<int> hiddenTiles({
  required int count,
  required double tileWidth,
  required double gap,
  required double offset,
  required double viewport,
}) {
  final hidden = <int>{};
  if (viewport <= 0) return hidden;
  for (var i = 0; i < count; i++) {
    final left = i * (tileWidth + gap) - offset;
    if (left + tileWidth <= 0 || left >= viewport) hidden.add(i);
  }
  return hidden;
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
    // Stats exist for anything you receive: a watched stream or someone else's camera.
    final statsTile = !focus.member.isMe;
    // Your own picture has no received stats, but what you send is still worth showing.
    final statsPanel = actions.showStats && (statsTile || actions.tx.isNotEmpty);
    final statsButton = statsTile || actions.tx.isNotEmpty;
    return Column(children: [
      Expanded(
        child: KeyedSubtree(
          key: const ValueKey('focused'),
          child: Stack(children: [
            Positioned.fill(child: _tile(focus, large: true)),
            if (statsPanel)
              Positioned(left: 8, top: 40, child: _StatsPanel(statsTile ? actions.rx : null, actions.tx, receiving: statsTile, link: actions.link)),
            Positioned(
              top: 8,
              right: 8,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (statsButton) ...[
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
        _Strip(
          items: others,
          tileFor: _tile,
          onHidden: actions.onHidden,
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

/// The row of small tiles under the focused one. It scrolls when they do not fit, and tells
/// [onHidden] which tiles are out of view.
class _Strip extends StatefulWidget {
  const _Strip({required this.items, required this.tileFor, this.onHidden});

  final List<StageItem> items;
  final Widget Function(StageItem) tileFor;
  final void Function(Set<String> keys)? onHidden;

  @override
  State<_Strip> createState() => _StripState();
}

class _StripState extends State<_Strip> {
  static const _tileWidth = 120 * 16 / 9, _gap = 8.0;
  final _scroll = ScrollController();
  Set<String> _reported = const {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_report);
  }

  void _report() {
    final cb = widget.onHidden;
    if (cb == null || !_scroll.hasClients) return;
    final hidden = hiddenTiles(
      count: widget.items.length,
      tileWidth: _tileWidth,
      gap: _gap,
      offset: _scroll.offset,
      viewport: _scroll.position.viewportDimension,
    );
    final keys = {for (final i in hidden) widget.items[i].key};
    if (keys.length == _reported.length && keys.containsAll(_reported)) return;
    _reported = keys;
    cb(keys);
  }

  @override
  void dispose() {
    _scroll.dispose();
    if (_reported.isNotEmpty) widget.onHidden?.call(const {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _report();
    });
    final items = widget.items;
    return SizedBox(
      key: const ValueKey('strip'),
      height: 120,
      child: Center(
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final i in items) ...[
              SizedBox(width: _tileWidth, height: 120, child: widget.tileFor(i)),
              if (i != items.last) const SizedBox(width: _gap),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The received resolution, frame rate and bitrate of the stream or camera on screen, then one line
/// for each of your own outgoing videos.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel(this.rx, this.tx, {this.receiving = true, this.link});

  /// The connection line, shown last.
  final String? link;

  final VideoRxSample? rx;
  final List<VideoTxSample> tx;

  /// Whether the focused tile is something received (so a missing sample means waiting).
  final bool receiving;

  /// `Sending screen 1920x1080 60 fps`, plus `limited by cpu` when libwebrtc holds an active
  /// layer back. Nothing at all while there is no picture to report.
  static List<String> _txLines(VideoTxSample t) {
    final top = t.layers.isEmpty
        ? null
        : t.layers.reduce((a, b) => (a.width ?? 0) * (a.height ?? 0) >= (b.width ?? 0) * (b.height ?? 0) ? a : b);
    final w = top?.width ?? t.captureWidth ?? 0;
    final h = top?.height ?? t.captureHeight ?? 0;
    if (w <= 0 || h <= 0) return const [];
    final fps = top?.framesPerSecond ?? t.captureFps ?? 0;
    final why = t.layers
        .where((l) => (l.framesPerSecond ?? 0) > 0)
        .map((l) => l.limitation)
        .firstWhere((l) => l != null && l != 'none', orElse: () => null);
    return [
      'Sending ${t.source} ${w}x$h ${fps.round()} fps',
      if (why != null) 'limited by $why',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = rx;
    final lines = !receiving
        ? const <String>[]
        : r == null
        ? const ['Waiting for video…']
        : [
            '${r.width ?? 0}x${r.height ?? 0}',
            '${(r.framesPerSecond ?? 0).round()} fps',
            '${(r.kbps ?? 0).round()} kbps',
          ];
    final own = [for (final t in tx) ..._txLines(t), ?link];
    if (lines.isEmpty && own.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final l in [...lines, ...own])
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
