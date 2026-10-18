import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The leftmost column: the Hubbub home mark, one icon per community, and importing a
/// community file.
class CommunityRail extends StatelessWidget {
  const CommunityRail({
    super.key,
    required this.communities,
    required this.selected,
    required this.onImport,
  });

  final List<String> communities;

  /// Index into [communities], or null.
  final int? selected;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: HubColors.rail,
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        children: [
          const _RailItem(
            tooltip: 'Hubbub',
            selected: false,
            idle: HubColors.main,
            active: HubColors.accent,
            child: _HubbubMark(),
          ),
          Center(
            child: Container(
              width: 32,
              height: 2,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: HubColors.divider,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
          for (var i = 0; i < communities.length; i++)
            _RailItem(
              tooltip: communities[i],
              selected: i == selected,
              idle: HubColors.accent,
              active: HubColors.accent,
              child: Text(
                initials(communities[i]),
                style: const TextStyle(
                  fontFamily: hubFont,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: HubColors.white,
                ),
              ),
            ),
          _RailItem(
            tooltip: 'Import community file',
            selected: false,
            idle: HubColors.main,
            active: HubColors.green,
            onTap: onImport,
            child: const _ImportGlyph(),
          ),
        ],
      ),
    );
  }
}

/// "Game Night" -> "GN"; at most three characters, like Discord's text icons.
String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final s = words.map((w) => w.characters.first).join();
  return s.characters.take(3).toString();
}

/// A 48 px rail icon: a circle that morphs into a rounded square on hover or when
/// selected, with the white pill on the rail's left edge.
class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.tooltip,
    required this.selected,
    required this.idle,
    required this.active,
    required this.child,
    this.onTap,
  });

  final String tooltip;
  final bool selected;
  final Color idle;
  final Color active;
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected || _hover;
    const duration = Duration(milliseconds: 150);
    return SizedBox(
      height: 56,
      child: Stack(children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 8,
          child: Center(
            child: AnimatedContainer(
              duration: duration,
              width: 4,
              height: widget.selected ? 40 : (_hover ? 20 : 0),
              decoration: const BoxDecoration(
                color: HubColors.white,
                borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Tooltip(
            message: widget.tooltip,
            // To the right of the icon, as in Discord.
            positionDelegate: (c) => Offset(
              c.target.dx + c.targetSize.width / 2 + 12,
              c.target.dy - c.tooltipSize.height / 2,
            ),
            waitDuration: Duration.zero,
            textStyle: const TextStyle(
              fontFamily: hubFont,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: HubColors.header,
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOut,
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? widget.active : widget.idle,
                    borderRadius: BorderRadius.circular(on ? 16 : 24),
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: on && widget.active == HubColors.green
                          ? HubColors.white
                          : HubColors.green,
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ImportGlyph extends StatelessWidget {
  const _ImportGlyph();

  @override
  Widget build(BuildContext context) => const Icon(Icons.add_rounded, size: 26);
}

/// Hubbub's own mark, as in the app icon: three heads whose shoulders join into one
/// speech bubble.
class _HubbubMark extends StatelessWidget {
  const _HubbubMark();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(28, 24), painter: _MarkPainter());
}

/// Circles and corners fitted to the 1254 px icon master (docs/brand/hubbub-icon.png),
/// in its pixel coordinates; the symbol spans x 180–1073 and y 254–1016 there.
class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    const left = 180.0, top = 254.0, width = 893.0, height = 762.0;
    final k = math.min(s.width / width, s.height / height);
    canvas
      ..translate((s.width - width * k) / 2, (s.height - height * k) / 2)
      ..scale(k)
      ..translate(-left, -top);
    final paint = Paint()..color = HubColors.white;
    // Heads, then the shoulders.
    for (final (x, y, r) in [
      (343.0, 452.0, 107.0), (626.0, 392.0, 138.0), (910.0, 455.0, 108.0),
      (343.0, 714.0, 157.0), (626.0, 684.0, 169.0), (910.0, 714.0, 157.0),
    ]) {
      canvas.drawCircle(Offset(x, y), r, paint);
    }
    // The bubble's body under the shoulders, and its tail.
    const corner = Radius.elliptical(219, 157);
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(180, 714, 1073, 902, bottomLeft: corner, bottomRight: corner),
      paint,
    );
    canvas.drawPath(
      Path()..addPolygon(const [Offset(346, 890), Offset(500, 902), Offset(293, 1016)], true),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
