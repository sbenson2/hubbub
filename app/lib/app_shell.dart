import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'links.dart';

/// The window and tray, behind one seam so the close/quit logic runs in widget tests without a
/// native window. The real one is [PluginAppShell].
abstract class AppShell {
  /// True once a tray (menu-bar) icon was actually created. Without one, closing the window must
  /// quit, because the user would have no way to bring it back or quit.
  bool get hasTray;

  /// Called when the user closes the window (X, Alt+F4).
  set onCloseRequested(void Function() cb);

  /// Called when the tray icon is clicked or its "Open Hubbub" is chosen.
  set onTrayOpen(void Function() cb);

  /// Called when the tray menu's "Quit Hubbub" is chosen.
  set onTrayQuit(void Function() cb);

  /// Creates the tray icon (if the platform can show one) and takes over the window's close button.
  Future<void> start();

  Future<void> hideWindow();
  Future<void> showWindow();

  /// Ends the process. Only called after the hub has shut down.
  Future<void> exitApp();
}

/// Remembers, per machine, that the "still running in the tray" notice was shown.
class HideNoticeStore {
  HideNoticeStore.file(String this._path) : _memory = false;
  HideNoticeStore.memory([bool shown = false])
      : _path = null,
        _memory = shown;

  final String? _path;
  bool _memory;

  Future<bool> get shown async {
    final path = _path;
    if (path == null) return _memory;
    try {
      final j = jsonDecode(await File(path).readAsString());
      return j is Map && j['hideNoticeShown'] == true;
    } catch (_) {
      return false; // missing or unreadable: not shown yet
    }
  }

  Future<void> markShown() async {
    final path = _path;
    if (path == null) {
      _memory = true;
      return;
    }
    try {
      await File(path).writeAsString(jsonEncode({'hideNoticeShown': true}));
    } catch (e) {
      debugPrint('could not save the tray notice flag: $e');
    }
  }
}

/// What closing the window and the tray menu do. Closing hides the window when a tray icon
/// exists and the hub keeps running; Quit (or closing with no tray) shuts the hub down, then exits.
class TrayLifecycle {
  TrayLifecycle({
    required this.shell,
    required this.shutdown,
    required this.notice,
    this.showNotice,
  });

  final AppShell shell;
  final Future<void> Function() shutdown;
  final HideNoticeStore notice;

  /// Tells the user, once, that Hubbub keeps running in the tray. Awaited before the window hides.
  final Future<void> Function()? showNotice;

  Future<void> start() async {
    shell.onCloseRequested = () => unawaited(_close());
    shell.onTrayOpen = () => unawaited(shell.showWindow());
    shell.onTrayQuit = () => unawaited(quit());
    await shell.start();
  }

  Future<void> _close() async {
    if (!shell.hasTray) return quit(); // nothing to bring the window back or quit from
    if (!await notice.shown) {
      await notice.markShown();
      await showNotice?.call();
    }
    await shell.hideWindow();
  }

  Future<void>? _quitting;

  /// Shuts down once; a second request while it runs joins the first. The process ends even if
  /// the shutdown fails: the user asked to quit.
  Future<void> quit() => _quitting ??= () async {
        try {
          await shutdown();
        } catch (e) {
          debugPrint('shutdown failed: $e');
        }
        await shell.exitApp();
      }();
}

/// Shows the window whenever a link arrives, so a link sent to a hidden Hubbub opens it.
class WindowRevealingLinks implements LinkSource {
  WindowRevealingLinks(this._inner, this._shell);

  final LinkSource _inner;
  final AppShell _shell;

  @override
  Future<String?> initial() => _inner.initial();

  @override
  Stream<String> get stream => _inner.stream.map((link) {
        unawaited(_shell.showWindow());
        return link;
      });
}
