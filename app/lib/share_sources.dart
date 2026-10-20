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

/// This many thumbnail calls in a row that the plugin answers with an error end the wait: the
/// portal session is not coming up, so there is no point waiting out the full timeout.
const portalMaxErrors = 5;

/// [PortalScreenSource] for the desktop. Asks for Screen sources only (a Window listing is
/// not available through the portal). Listing the Screen sources is what opens the system
/// dialog, so it happens once. The one source is a placeholder; the user's pick is known once
/// the portal stream delivers a picture, so a non-empty thumbnail means the pick was made.
///
/// Every attempt starts a fresh system session (the plugin drops the old one when Screen
/// sources are listed), and none leaves one behind: unless a pick is returned, [release] closes
/// the session (and so the system dialog) on cancel, timeout and error. A failing [release] is
/// logged and ignored.
Future<String?> portalScreenSource(
  PortalCancel cancel, {
  Future<List<ShareSource>> Function()? list,
  Future<Uint8List?> Function(String id)? thumbnail,
  Future<void> Function()? release,
  Duration interval = portalPollInterval,
  Duration timeout = portalPickTimeout,
}) async {
  var picked = false;
  try {
    final id = await _waitForPick(cancel, list ?? _portalSources, thumbnail ?? _portalThumbnail, interval, timeout);
    picked = id != null;
    return id;
  } finally {
    if (!picked) {
      try {
        await (release ?? releasePortalScreen)();
      } catch (e) {
        debugPrint('hubbub: closing the screen share session failed: $e');
      }
    }
  }
}

Future<String?> _waitForPick(
  PortalCancel cancel,
  Future<List<ShareSource>> Function() list,
  Future<Uint8List?> Function(String id) getThumbnail,
  Duration interval,
  Duration timeout,
) async {
  final sources = await list();
  if (cancel.cancelled) return null;
  if (sources.isEmpty) throw StateError('The system share prompt offered no screen');
  final id = sources.first.id;
  var waited = Duration.zero;
  var errors = 0;
  while (!cancel.cancelled) {
    try {
      final picture = await getThumbnail(id);
      errors = 0;
      if (picture != null && picture.isNotEmpty && !cancel.cancelled) return id;
    } catch (e) {
      // Usually not ready yet (the dialog is still open): look again. Several in a row mean
      // the session is dead, and the error is the answer.
      if (++errors >= portalMaxErrors) rethrow;
    }
    if (cancel.cancelled) break;
    if (waited >= timeout) throw TimeoutException('No screen was chosen in the system dialog', timeout);
    await Future<void>.delayed(interval);
    waited += interval;
  }
  return null;
}

/// Closes the portal session of the Screen list the plugin keeps (and with it the system
/// dialog, if it is still open). Does nothing on the other platforms and sessions.
Future<void> releasePortalScreen() => rtc.WebRTC.invokeMethod<bool, void>('hubbubReleasePortalScreen');

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
/// handle is destroyed (a window's id is its HWND). Listing sources captures every screen
/// and window, so a screen is looked up at most once per [ScreenSourceCheck.screenRecheck]
/// (a window is checked on every call, and on Windows that is a cheap `IsWindow`).
Future<bool> desktopSourceExists(String id) => _desktopCheck.exists(id);

typedef SourceLister = Future<List<ShareSource>> Function();

class ScreenSourceCheck {
  ScreenSourceCheck({required this.list, this.isWindow, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The screens and windows the platform lists now.
  final SourceLister list;

  /// A cheap test that [id] is a live window (Windows); null where there is none.
  final bool Function(String id)? isWindow;
  final DateTime Function() _now;

  /// How long a screen that was listed stays believed. A removed monitor shows up at the
  /// next recheck, and the capture of it has stopped delivering frames by then anyway.
  static const screenRecheck = Duration(seconds: 30);

  final _screens = <String>{};
  DateTime? _screensListed;

  Future<bool> exists(String id) async {
    if (isWindow?.call(id) ?? false) return true;
    final listed = _screensListed;
    if (listed != null && _screens.contains(id) && _now().difference(listed) < screenRecheck) return true;
    final all = await list();
    _screens
      ..clear()
      ..addAll([for (final s in all) if (s.kind == ShareKind.screen) s.id]);
    _screensListed = _now();
    return all.any((s) => s.id == id);
  }
}

final _desktopCheck = ScreenSourceCheck(
  list: () async {
    final all = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen, rtc.SourceType.Window]);
    return [
      for (final s in all)
        ShareSource(
          id: s.id,
          name: s.name,
          kind: s.type == rtc.SourceType.Screen ? ShareKind.screen : ShareKind.window,
        ),
    ];
  },
  isWindow: Platform.isWindows
      ? (id) {
          final hwnd = int.tryParse(id);
          return hwnd != null && _isWindow(hwnd) != 0;
        }
      : null,
);

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
