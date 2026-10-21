import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ui/channel_sidebar.dart';
import 'game_rules.dart';
import 'overlay_host.dart';
import 'overlay_prefs.dart';
import 'overlay_scene.dart';

/// How long a game list read stays fresh before an unknown windowed exe triggers a re-read.
const gameListRefresh = Duration(seconds: 30);

/// Decides when the in-game overlay shows, where it sits and what it draws.
///
/// It turns three inputs (the call's members, the overlay settings and the foreground window's
/// facts) into `start`, `stop`, `show`, `move` and `hide` calls on an [OverlayHost]. It lives for
/// the whole process: its subscriptions are never cancelled.
///
/// One apply loop runs at a time. Every input only records its value and marks the state dirty;
/// each pass of the loop reads the latest state and makes the host calls it needs, one after
/// another. So [OverlayHost] never sees a `hide` or `stop` overlap a `show`: they follow it,
/// and a burst of changes during a slow draw collapses into one pass over the final state. A
/// pass that finds the state changed under it (after `start` or `knownGames`) ends early, before
/// drawing, and the next pass starts over.
class GameOverlayController {
  GameOverlayController({
    required this._host,
    required this.settings,
    this._clock = DateTime.now,
  }) {
    // Subscribe before `start()`: the stream has no replay, and `start` triggers the first facts.
    _host.foreground.listen(_onForeground);
    settings.addListener(_kick);
  }

  final OverlayHost _host;
  final OverlaySettings settings;
  final DateTime Function() _clock;

  List<VoiceMember>? _members;

  /// Whether `start()` has succeeded and no `stop()` has followed.
  bool _on = false;
  ForegroundFacts? _facts;
  Set<String> _games = const {};
  DateTime? _gamesAt;

  // What the overlay window currently shows.
  bool _visible = false;
  OverlayScene? _scene;
  Point<int>? _origin;
  int? _hwnd;

  bool _dirty = false;
  bool _running = false;

  /// [members] in sidebar order, you included; null when not in a call.
  void setCall(List<VoiceMember>? members) {
    _members = members;
    _kick();
  }

  bool get _wanted => _members != null && settings.prefs.enabled;

  void _onForeground(ForegroundFacts? facts) {
    if (!_wanted || facts == _facts) return; // late facts after a stop are dropped
    _facts = facts;
    _kick();
  }

  void _kick() {
    _dirty = true;
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      while (_dirty) {
        _dirty = false;
        await _pass();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _pass() async {
    final members = _members;
    final prefs = settings.prefs;
    if (members == null || !prefs.enabled) {
      // `stop` hides the window itself, so no `hide` follows it.
      final wasOn = _on;
      _on = false;
      _visible = false;
      _facts = null;
      _scene = null;
      _origin = null;
      _hwnd = null;
      if (wasOn) await _guard('stop', _host.stop);
      return;
    }

    if (!_on) {
      if (!await _guard('start', _host.start)) return; // the next input retries
      _on = true;
      await _readGames();
      if (_dirty) return;
    }

    final f = _facts;
    if (f != null &&
        !f.own &&
        f.path.isNotEmpty &&
        !isExcluded(f) &&
        !_games.contains(normalizeExePath(f.path)) &&
        _clock().difference(_gamesAt!) >= gameListRefresh) {
      await _readGames();
      if (_dirty) return;
    }

    final rows = overlayRows(members, prefs);
    if (f == null || rows.isEmpty || !isGameInFront(f, _games)) {
      if (_visible && await _guard('hide', _host.hide)) _visible = false;
      return;
    }

    final scene =
        OverlayScene(rows: rows, avatarSize: prefs.avatarSize, pixelRatio: f.dpi / 96);
    final origin = overlayOrigin(f);
    if (scene != _scene) {
      // A failed draw may still have left the window visible, so assume it is.
      _scene = null;
      _visible = true;
      if (await _guard('show', () => _host.show(scene, origin))) {
        _scene = scene;
        _origin = origin;
        _hwnd = f.hwnd;
      }
    } else if (!_visible || origin != _origin || f.hwnd != _hwnd) {
      // Also the topmost re-assert when another window or game took the front.
      if (await _guard('move', () => _host.move(origin))) {
        _visible = true;
        _origin = origin;
        _hwnd = f.hwnd;
      }
    }
  }

  Future<void> _readGames() async {
    _gamesAt = _clock();
    await _guard('knownGames', () async => _games = await _host.knownGames());
  }

  /// Runs a host call; false after logging when it throws. A `bad_image` from `show` can be
  /// transient, so no error stops the overlay for good.
  Future<bool> _guard(String what, Future<void> Function() call) async {
    try {
      await call();
      return true;
    } catch (e) {
      debugPrint('overlay $what failed: $e');
      return false;
    }
  }
}
