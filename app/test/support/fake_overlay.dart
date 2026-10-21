import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:hubbub/overlay/game_rules.dart';
import 'package:hubbub/overlay/overlay_host.dart';
import 'package:hubbub/overlay/overlay_scene.dart';

/// An [OverlayHost] that records what the controller asks of it.
class FakeOverlayHost implements OverlayHost {
  /// `'start'`, `'stop'`, `'knownGames'`, `'show x,y'`, `'move x,y'` and `'hide'`, in call order.
  /// A call is recorded when it begins, before it waits on [showGate].
  final calls = <String>[];

  /// Each scene passed to `show`.
  final scenes = <OverlayScene>[];

  /// What `knownGames` returns.
  Set<String> games = {};

  /// While set, `show` waits for it after recording itself.
  Completer<void>? showGate;

  /// Makes the next `show` throw a `bad_image` [PlatformException].
  bool failNextShow = false;

  final _foreground = StreamController<ForegroundFacts?>.broadcast();

  /// Sends [f] as the native `foreground` event.
  void emit(ForegroundFacts? f) => _foreground.add(f);

  @override
  Stream<ForegroundFacts?> get foreground => _foreground.stream;

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<Set<String>> knownGames() async {
    calls.add('knownGames');
    return games;
  }

  @override
  Future<void> show(OverlayScene scene, Point<int> origin) async {
    calls.add('show ${origin.x},${origin.y}');
    scenes.add(scene);
    if (failNextShow) {
      failNextShow = false;
      throw PlatformException(code: 'bad_image');
    }
    await showGate?.future;
  }

  @override
  Future<void> move(Point<int> origin) async => calls.add('move ${origin.x},${origin.y}');

  @override
  Future<void> hide() async => calls.add('hide');
}
