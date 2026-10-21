import 'package:flutter/foundation.dart';

import '../ui/channel_sidebar.dart';
import 'overlay_prefs.dart';

/// One avatar bubble in the overlay.
@immutable
class OverlayRow {
  const OverlayRow({
    required this.id,
    required this.name,
    required this.speaking,
    required this.muted,
    required this.deafened,
    required this.showName,
  });

  final String id;
  final String name;
  final bool speaking;
  final bool muted;
  final bool deafened;
  final bool showName;

  @override
  bool operator ==(Object other) =>
      other is OverlayRow &&
      other.id == id &&
      other.name == name &&
      other.speaking == speaking &&
      other.muted == muted &&
      other.deafened == deafened &&
      other.showName == showName;

  @override
  int get hashCode => Object.hash(id, name, speaking, muted, deafened, showName);
}

/// Everything one overlay image depends on; equal scenes draw identical pixels.
@immutable
class OverlayScene {
  const OverlayScene({required this.rows, required this.avatarSize, required this.pixelRatio});

  final List<OverlayRow> rows;
  final OverlayAvatarSize avatarSize;
  final double pixelRatio;

  @override
  bool operator ==(Object other) =>
      other is OverlayScene &&
      other.avatarSize == avatarSize &&
      other.pixelRatio == pixelRatio &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(avatarSize, pixelRatio, Object.hashAll(rows));
}

/// The rows to show for [members] (in their order, you included) under [prefs].
List<OverlayRow> overlayRows(List<VoiceMember> members, OverlayPrefs prefs) => [
      for (final m in members)
        if (prefs.users == OverlayUsers.always || m.speaking)
          OverlayRow(
            id: m.id,
            name: m.name,
            speaking: m.speaking,
            // The sidebar shows a deafened member as muted too.
            muted: m.muted || m.deafened,
            deafened: m.deafened,
            showName: switch (prefs.names) {
              OverlayNames.always => true,
              OverlayNames.whileSpeaking => m.speaking,
              OverlayNames.never => false,
            },
          ),
    ];
