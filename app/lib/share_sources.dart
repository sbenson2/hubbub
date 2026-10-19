import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

enum ShareKind { screen, window }

/// A screen or a window the OS lets us capture, as the share picker lists it.
class ShareSource {
  const ShareSource({required this.id, required this.name, required this.kind, this.thumbnail});
  final String id;
  final String name;
  final ShareKind kind;

  /// JPEG, when the platform produced one.
  final Uint8List? thumbnail;
}

/// Lists what can be shared right now. Throws when the platform has no desktop capture.
typedef ShareSourceLoader = Future<List<ShareSource>> Function();

/// The screens and windows from flutter_webrtc's desktop capturer (`desktopCapturer.getSources`
/// with 320x180 thumbnails).
Future<List<ShareSource>> desktopShareSources() async {
  final all = await rtc.desktopCapturer.getSources(
    types: [rtc.SourceType.Screen, rtc.SourceType.Window],
    thumbnailSize: rtc.ThumbnailSize(320, 180),
  );
  return [
    for (final s in all)
      ShareSource(
        id: s.id,
        name: s.name,
        kind: s.type == rtc.SourceType.Screen ? ShareKind.screen : ShareKind.window,
        thumbnail: s.thumbnail,
      ),
  ];
}
