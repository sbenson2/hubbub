import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show HubbubCamera;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_shell.dart';

/// The real window and tray: `window_manager` takes over the close button, `tray_manager`
/// draws the notification-area (Linux: AppIndicator, macOS: menu-bar) icon.
class PluginAppShell with TrayListener, WindowListener implements AppShell {
  static const _openKey = 'open', _quitKey = 'quit';

  /// Per platform: `.ico` on Windows, `.png` elsewhere. Bundled via the `assets/tray/` entry.
  static String get _icon => Platform.isWindows ? 'assets/tray/app_icon.ico' : 'assets/tray/icon.png';

  /// The runner (windows/runner/flutter_window.cpp) calls `sessionEnd` when Windows logs off or
  /// shuts down, and `quit` when `hubbub.exe --quit` reaches this instance.
  static const _native = MethodChannel('dev.hubbub/session');

  bool _hasTray = false;
  void Function() _close = () {}, _open = () {}, _quit = () {};
  Future<void> Function() _session = () async {};

  @override
  bool get hasTray => _hasTray;
  @override
  set onCloseRequested(void Function() cb) => _close = cb;
  @override
  set onTrayOpen(void Function() cb) => _open = cb;
  @override
  set onTrayQuit(void Function() cb) => _quit = cb;
  @override
  set onSessionEnd(Future<void> Function() cb) => _session = cb;

  @override
  Future<void> start() async {
    _native.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'sessionEnd':
          await _session();
          await _restoreCamera();
        case 'quit':
          _quit();
      }
      return null;
    });
    await windowManager.ensureInitialized();
    _hasTray = await _createTray();
    // Take the close button either way: with a tray it hides, without one the lifecycle quits.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
  }

  Future<bool> _createTray() async {
    try {
      if (!await _trayHostPresent()) return false;
      await trayManager.setIcon(_icon);
      if (!Platform.isLinux) await trayManager.setToolTip('Hubbub'); // AppIndicator has no tooltip
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: _openKey, label: 'Open Hubbub'),
        MenuItem.separator(),
        MenuItem(key: _quitKey, label: 'Quit Hubbub'),
      ]));
      trayManager.addListener(this);
      return true;
    } catch (e) {
      debugPrint('no tray icon: $e');
      return false;
    }
  }

  /// Windows and macOS always have a notification area. On Linux the AppIndicator call succeeds
  /// even when nothing draws it (GNOME without the AppIndicator extension), so ask the session
  /// bus whether a StatusNotifierWatcher is running; `gdbus` ships with GLib.
  static Future<bool> _trayHostPresent() async {
    if (!Platform.isLinux) return true;
    try {
      final r = await Process.run('gdbus', [
        'call', '--session',
        '--dest', 'org.freedesktop.DBus',
        '--object-path', '/org/freedesktop/DBus',
        '--method', 'org.freedesktop.DBus.NameHasOwner',
        'org.kde.StatusNotifierWatcher',
      ]).timeout(const Duration(seconds: 3));
      return r.exitCode == 0 && '${r.stdout}'.contains('true');
    } catch (_) {
      return false; // cannot tell: assume no tray, so closing quits rather than strands the app
    }
  }

  @override
  Future<void> hideWindow() => windowManager.hide();

  @override
  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Windows: the webcam's auto-exposure priority goes back before the process ends. exit() runs
  /// no native destructors. Short timeout, so a quit never hangs on it.
  Future<void> _restoreCamera() async {
    if (!HubbubCamera.supported) return;
    try {
      await HubbubCamera.restoreExposure().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> exitApp() async {
    await _restoreCamera();
    // exit() runs no window destructors, which would leave a ghost icon in the notification area.
    if (_hasTray) {
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
    exit(0);
  }

  // WindowListener
  @override
  void onWindowClose() => _close();

  // TrayListener. On Windows a left click opens the window and a right click pops the menu;
  // Linux and macOS draw the menu themselves.
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) _open();
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _openKey:
        _open();
      case _quitKey:
        _quit();
    }
  }
}
