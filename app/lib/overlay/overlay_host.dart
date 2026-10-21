import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'game_rules.dart';
import 'overlay_renderer.dart';
import 'overlay_scene.dart';

/// Turns a scene into overlay pixels; the app passes `rasterizeScene`.
typedef OverlayRasterizer = Future<OverlayBitmap> Function(OverlayScene scene);

/// The Windows runner's overlay window and foreground watcher.
abstract class OverlayHost {
  /// The foreground window's facts, one event per native `foreground` call: null when there is
  /// no foreground window or the facts are malformed. A broadcast stream.
  Stream<ForegroundFacts?> get foreground;

  /// Installs the foreground hooks; the current facts follow at once on [foreground].
  Future<void> start();

  /// Removes the hooks and hides the overlay.
  Future<void> stop();

  /// The executables Windows recognises as games, passed through [normalizeExePath].
  Future<Set<String>> knownGames();

  /// Rasterizes [scene], shows it and puts its top-left at [origin] (screen physical px).
  Future<void> show(OverlayScene scene, Point<int> origin);

  /// Moves the overlay to [origin] without redrawing it, and re-asserts topmost.
  Future<void> move(Point<int> origin);

  Future<void> hide();
}

/// [OverlayHost] over the `dev.hubbub/overlay` method channel (Windows runner,
/// `flutter_window.cpp`).
///
/// | Direction | Method | Arguments | Result |
/// |---|---|---|---|
/// | Dart → native | `setImage` | `{rgba: Uint8List, width: int, height: int}`: premultiplied RGBA, top-down, physical px | `null`; error `bad_image` (see below) |
/// | Dart → native | `place` | `{x: int, y: int}`: screen physical px of the top-left | `null`; moves, re-asserts topmost, shows without activating |
/// | Dart → native | `hide` | none | `null` |
/// | Dart → native | `start` | none | `null`; installs hooks, and current facts follow at once |
/// | Dart → native | `stop` | none | `null`; unhooks and hides |
/// | Dart → native | `knownGames` | none | `List<String>`: every `MatchedExeFullPath` under `HKCU\System\GameConfigStore\Children\*` |
/// | native → Dart | `foreground` | facts map (see [ForegroundFacts.fromMap]), or `null` when there's no foreground window | ignored |
///
/// `place` and `hide` before the first image succeed and do nothing. `bad_image` means the image
/// is empty or `rgba.length != width*height*4`, but also that the native draw failed (the window
/// or bitmap couldn't be made, or Windows refused the image). Treat it as possibly transient: the
/// window keeps its old image, and the next `setImage` tries again. [show] passes the error on
/// as a [PlatformException].
class ChannelOverlayHost implements OverlayHost {
  /// Takes over [channel]'s method-call handler, for `foreground`.
  ChannelOverlayHost({
    required this._rasterize,
    this._channel = const MethodChannel('dev.hubbub/overlay'),
  }) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final OverlayRasterizer _rasterize;
  final MethodChannel _channel;
  final _foreground = StreamController<ForegroundFacts?>.broadcast();

  @override
  Stream<ForegroundFacts?> get foreground => _foreground.stream;

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'foreground') throw MissingPluginException();
    _foreground.add(ForegroundFacts.fromMap(call.arguments));
    return null;
  }

  @override
  Future<void> start() => _channel.invokeMethod<void>('start');

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<Set<String>> knownGames() async {
    final paths = await _channel.invokeListMethod<String>('knownGames') ?? const <String>[];
    return {for (final path in paths) normalizeExePath(path)};
  }

  @override
  Future<void> show(OverlayScene scene, Point<int> origin) async {
    final bitmap = await _rasterize(scene);
    await _channel.invokeMethod<void>(
        'setImage', {'rgba': bitmap.rgba, 'width': bitmap.width, 'height': bitmap.height});
    await move(origin);
  }

  @override
  Future<void> move(Point<int> origin) =>
      _channel.invokeMethod<void>('place', {'x': origin.x, 'y': origin.y});

  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');
}
