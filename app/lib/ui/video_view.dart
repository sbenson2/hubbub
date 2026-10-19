import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' show VideoTrackRenderer, VideoViewFit, VideoViewMirrorMode;

import '../room_adapter.dart';

/// Renders one [VideoFeed]. Without a track (a share nobody watches yet, or a fake in a test)
/// it is an empty black box, so the layout is the same.
class VideoView extends StatelessWidget {
  const VideoView({super.key, required this.feed, this.mirror = false, this.contain = false});

  final VideoFeed feed;

  /// Your own camera preview is mirrored, as in Discord.
  final bool mirror;

  /// Letterbox instead of filling the box (a focused stream must not be cropped).
  final bool contain;

  @override
  Widget build(BuildContext context) {
    final track = feed.track;
    return KeyedSubtree(
      key: ValueKey('video:${feed.sid}'),
      child: track == null
          ? const ColoredBox(color: Colors.black)
          : ColoredBox(
              color: Colors.black,
              child: VideoTrackRenderer(
                track,
                fit: contain ? VideoViewFit.contain : VideoViewFit.cover,
                mirrorMode: mirror ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
              ),
            ),
    );
  }
}
