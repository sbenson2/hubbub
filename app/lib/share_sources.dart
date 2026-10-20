import 'dart:async';
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

/// Lets the user back out of a portal share while it waits for GNOME's dialog.
class PortalCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Waits for the user to pick a screen in the system's own share prompt (Wayland) and returns
/// the source id to capture. Null when [PortalCancel.cancel] was called; throws a
/// [TimeoutException] when nobody picked in time.
typedef PortalScreenSource = Future<String?> Function(PortalCancel cancel);

/// How often the portal loader looks for the first picture, and how long it waits for a pick.
const portalPollInterval = Duration(milliseconds: 500);
const portalPickTimeout = Duration(minutes: 2);

/// [PortalScreenSource] for the desktop. Asks for Screen sources only (a Window listing is
/// not available through the portal). Listing the Screen sources is what opens the system
/// dialog, so it happens once. The one source is a placeholder; the user's pick is known once
/// the portal stream delivers a picture, so a non-empty thumbnail means the pick was made.
Future<String?> portalScreenSource(
  PortalCancel cancel, {
  Future<List<ShareSource>> Function()? list,
  Future<Uint8List?> Function(String id)? thumbnail,
  Duration interval = portalPollInterval,
  Duration timeout = portalPickTimeout,
}) async {
  final sources = await (list ?? _portalSources)();
  if (cancel.cancelled) return null;
  if (sources.isEmpty) throw StateError('The system share prompt offered no screen');
  final id = sources.first.id;
  final getThumbnail = thumbnail ?? _portalThumbnail;
  var waited = Duration.zero;
  while (!cancel.cancelled) {
    try {
      final picture = await getThumbnail(id);
      if (picture != null && picture.isNotEmpty && !cancel.cancelled) return id;
    } catch (e) {
      // Not ready yet (or the dialog is still open): look again.
    }
    if (cancel.cancelled) break;
    if (waited >= timeout) throw TimeoutException('Nobody chose a screen in the system dialog', timeout);
    await Future<void>.delayed(interval);
    waited += interval;
  }
  return null;
}

Future<List<ShareSource>> _portalSources() async {
  final all = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen]);
  return [for (final s in all) ShareSource(id: s.id, name: s.name, kind: ShareKind.screen)];
}

/// Asks the plugin to grab the portal stream's current frame; it answers with the frame
/// grabbed by the previous ask, empty until the stream is live.
Future<Uint8List?> _portalThumbnail(String id) => rtc.WebRTC.invokeMethod<Uint8List, Map<String, dynamic>>(
      'getDesktopSourceThumbnail',
      <String, dynamic>{
        'sourceId': id,
        'thumbnailSize': {'width': 320, 'height': 180},
      },
    );

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
