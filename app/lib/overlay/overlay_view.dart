import 'package:flutter/material.dart';

import '../ui/avatar.dart';
import '../ui/theme.dart';
import 'overlay_prefs.dart';
import 'overlay_renderer.dart';
import 'overlay_scene.dart';

/// Every size and colour of the overlay, in logical px. Large / small where they differ.
abstract final class OverlayLook {
  static double avatar(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 32 : 24;
  static double nameSize(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 14 : 12;
  static double tagHeight(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 24 : 20;
  static double tagPadding(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 8 : 6;
  static double tagGap(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 6 : 4;
  static double icon(OverlayAvatarSize s) => s == OverlayAvatarSize.large ? 16 : 14;

  static const tagColor = Color(0xB31E1F22);
  static const tagRadius = 4.0;
  static const maxTagWidth = 200.0;
  static const rowGap = 4.0;
  static const quietOpacity = 0.6;
  static const speakingOpacity = 1.0;
  static const iconColor = HubColors.interactive;
  static const iconStrike = HubColors.red;
  static const iconStrikeBackground = HubColors.rail;
  static const nameColor = HubColors.white;
  static const nameHeight = 1.2;
  static const iconGap = 4.0;
  static const clear = Color(0x00000000);
}

/// The overlay's bubbles. Renders offscreen with only a Directionality above it: no Material,
/// Tooltip or anything that needs an Overlay or Navigator.
class GameOverlayView extends StatelessWidget {
  const GameOverlayView({super.key, required this.scene});

  final OverlayScene scene;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < scene.rows.length; i++) ...[
            if (i > 0) const SizedBox(height: OverlayLook.rowGap),
            _Row(key: Key('overlay-row:${scene.rows[i].id}'), row: scene.rows[i], size: scene.avatarSize),
          ],
        ],
      );
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.row, required this.size});

  final OverlayRow row;
  final OverlayAvatarSize size;

  @override
  Widget build(BuildContext context) {
    final icon = OverlayLook.icon(size);
    Widget crossed(IconData data) => CrossedIcon(
          data,
          size: icon,
          color: OverlayLook.iconColor,
          strike: OverlayLook.iconStrike,
          background: OverlayLook.iconStrikeBackground,
        );
    final icons = [
      if (row.muted) crossed(Icons.mic_rounded),
      if (row.deafened) crossed(Icons.headphones_rounded),
    ];
    final hasTag = row.showName || icons.isNotEmpty;
    return Opacity(
      opacity: row.speaking ? OverlayLook.speakingOpacity : OverlayLook.quietOpacity,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Avatar(
          id: row.id,
          name: row.name,
          size: OverlayLook.avatar(size),
          speaking: row.speaking,
          background: OverlayLook.clear,
        ),
        if (hasTag) ...[
          SizedBox(width: OverlayLook.tagGap(size)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: OverlayLook.maxTagWidth),
            child: Container(
              height: OverlayLook.tagHeight(size),
              padding: EdgeInsets.symmetric(horizontal: OverlayLook.tagPadding(size)),
              decoration: BoxDecoration(
                color: OverlayLook.tagColor,
                borderRadius: BorderRadius.circular(OverlayLook.tagRadius),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (row.showName)
                  Flexible(
                    child: Text(
                      row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: hubFont,
                        fontSize: OverlayLook.nameSize(size),
                        fontWeight: FontWeight.w600,
                        color: OverlayLook.nameColor,
                        height: OverlayLook.nameHeight,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                for (var i = 0; i < icons.length; i++) ...[
                  if (row.showName || i > 0) const SizedBox(width: OverlayLook.iconGap),
                  icons[i],
                ],
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

/// [scene] as pixels, at the scene's pixel ratio.
Future<OverlayBitmap> rasterizeScene(OverlayScene scene) =>
    renderOverlayImage(GameOverlayView(scene: scene), pixelRatio: scene.pixelRatio);
