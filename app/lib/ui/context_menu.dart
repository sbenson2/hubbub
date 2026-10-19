import 'package:flutter/material.dart';

import 'theme.dart';

/// Discord's context menu: a dark rounded box at the pointer, closed by a click anywhere
/// else. It opens upward when there is no room below, as the user panel's menus must.
Future<void> showHubMenu(BuildContext context, Offset at, WidgetBuilder builder,
        {double width = 220}) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close menu',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => CustomSingleChildLayout(
        delegate: _MenuPosition(at),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: width,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: HubColors.rail,
              borderRadius: BorderRadius.circular(4),
              boxShadow: const [
                BoxShadow(color: Color(0x52000000), blurRadius: 16, offset: Offset(0, 8)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Builder(builder: builder)],
            ),
          ),
        ),
      ),
    );

class _MenuPosition extends SingleChildLayoutDelegate {
  _MenuPosition(this.at);
  final Offset at;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => c.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = at.dx.clamp(8.0, (size.width - child.width - 8).clamp(8.0, double.infinity));
    final below = at.dy + child.height + 8 <= size.height;
    final y = below ? at.dy : (at.dy - child.height).clamp(8.0, double.infinity);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPosition old) => old.at != at;
}

/// A small caps section title inside a menu.
class MenuLabel extends StatelessWidget {
  const MenuLabel(this.text, {super.key, this.trailing});
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Row(children: [
          Expanded(child: Text(text, style: HubText.category)),
          if (trailing != null) Text(trailing!, style: HubText.category),
        ]),
      );
}

/// One row of a menu: highlighted in the accent colour on hover, like Discord's.
class MenuItem extends StatefulWidget {
  const MenuItem({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
  });
  final String label;
  final VoidCallback onTap;

  /// A radio or checkbox glyph shown before the label.
  final IconData? leading;

  @override
  State<MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<MenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = _hover ? HubColors.white : HubColors.interactive;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hover ? HubColors.accent : null,
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(children: [
            Expanded(
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: hubFont,
                      fontSize: 14,
                      height: 1.286,
                      fontWeight: FontWeight.w500,
                      color: fg)),
            ),
            if (widget.leading != null) Icon(widget.leading, size: 18, color: fg),
          ]),
        ),
      ),
    );
  }
}

/// A 0 to 200% slider with its percentage, as Discord's volume sliders. [onChanged] fires
/// while dragging; [onChangeEnd] when the pointer lets go, and after every change that is not
/// part of a drag (the keyboard), so each of those is saved too.
class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 6,
          activeTrackColor: HubColors.accent,
          inactiveTrackColor: HubColors.tertiary,
          thumbColor: HubColors.white,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: SliderComponentShape.noOverlay,
          trackShape: const RoundedRectSliderTrackShape(),
        ),
        child: Slider(
          value: widget.value.clamp(0.0, 2.0),
          min: 0,
          max: 2,
          onChangeStart: (_) => _dragging = true,
          onChanged: (v) {
            widget.onChanged(v);
            if (!_dragging) widget.onChangeEnd();
          },
          onChangeEnd: (_) {
            _dragging = false;
            widget.onChangeEnd();
          },
        ),
      );
}

/// "150%" for a volume of 1.5.
String percent(double v) => '${(v * 100).round()}%';
