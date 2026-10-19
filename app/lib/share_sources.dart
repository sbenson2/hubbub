import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:window_manager/window_manager.dart';

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

/// Whether the screen or window [id] still exists. Asks for no thumbnails, so it is cheap
/// enough to repeat while a share runs. Throws when the platform cannot list sources.
typedef ShareSourceCheck = Future<bool> Function(String id);

/// [ShareSourceCheck] for the desktop. The Windows window list leaves out minimized windows
/// and windows on another virtual desktop, so there a window counts as gone only once its
/// handle is destroyed (a window's id is its HWND).
Future<bool> desktopSourceExists(String id) async {
  if (Platform.isWindows) {
    final hwnd = int.tryParse(id);
    if (hwnd != null && _isWindow(hwnd) != 0) return true;
  }
  final all = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen, rtc.SourceType.Window]);
  return all.any((s) => s.id == id);
}

final _isWindow = DynamicLibrary.open('user32.dll')
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

/// Full-screen for the app window (a focused stream's Full Screen button).
Future<void> setWindowFullscreen(bool on) async {
  try {
    await windowManager.setFullScreen(on);
  } catch (e) {
    debugPrint('hubbub: full screen failed: $e');
  }
}
