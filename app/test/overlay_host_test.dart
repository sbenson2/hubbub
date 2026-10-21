import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/overlay/game_rules.dart';
import 'package:hubbub/overlay/overlay_host.dart';
import 'package:hubbub/overlay/overlay_prefs.dart';
import 'package:hubbub/overlay/overlay_renderer.dart';
import 'package:hubbub/overlay/overlay_scene.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.hubbub/overlay');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const scene = OverlayScene(rows: [], avatarSize: OverlayAvatarSize.large, pixelRatio: 1.5);

  late List<MethodCall> calls;
  late List<OverlayScene> rasterized;
  Object? Function(MethodCall call) reply = (_) => null;

  Future<OverlayBitmap> fakeRasterize(OverlayScene s) async {
    rasterized.add(s);
    return OverlayBitmap(rgba: Uint8List(8), width: 2, height: 1);
  }

  setUp(() {
    calls = [];
    rasterized = [];
    reply = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('show_sends_the_image_then_the_place', () async {
    final host = ChannelOverlayHost(rasterize: fakeRasterize);
    await host.show(scene, const Point(24, 40));
    expect(rasterized, [scene]);
    expect(calls.map((c) => c.method), ['setImage', 'place']);
    expect(calls[0].arguments, {'rgba': Uint8List(8), 'width': 2, 'height': 1});
    expect(calls[1].arguments, {'x': 24, 'y': 40});
  });

  test('move_and_hide_send_place_and_hide', () async {
    final host = ChannelOverlayHost(rasterize: fakeRasterize);
    await host.move(const Point(-1900, 16));
    await host.hide();
    expect(rasterized, isEmpty);
    expect(calls.map((c) => c.method), ['place', 'hide']);
    expect(calls[0].arguments, {'x': -1900, 'y': 16});
    expect(calls[1].arguments, isNull);
  });

  test('start_stop_and_known_games', () async {
    reply = (call) => call.method == 'knownGames' ? [r'C:\Games\Foo.EXE'] : null;
    final host = ChannelOverlayHost(rasterize: fakeRasterize);
    await host.start();
    final games = await host.knownGames();
    await host.stop();
    expect(calls.map((c) => c.method), ['start', 'knownGames', 'stop']);
    expect(games, {r'c:\games\foo.exe'});
  });

  test('native_foreground_calls_become_facts', () async {
    final host = ChannelOverlayHost(rasterize: fakeRasterize);
    final events = <ForegroundFacts?>[];
    final sub = host.foreground.listen(events.add);
    Future<void> deliver(Object? arguments) => messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('foreground', arguments)),
          (_) {},
        );

    await deliver({
      'hwnd': 4242,
      'path': r'C:\Games\Foo.exe',
      'own': false,
      'cls': 'FooWindow',
      'caption': false,
      'window': [-1920, 0, 0, 1080],
      'client': [-1920, 0, 0, 1080],
      'monitor': [-1920, 0, 0, 1080],
      'minimized': false,
      'dpi': 144,
    });
    await deliver(null);
    await deliver({'hwnd': 4242, 'path': 7});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    const screen = Rectangle<int>(-1920, 0, 1920, 1080);
    expect(events, [
      const ForegroundFacts(
        hwnd: 4242,
        path: r'C:\Games\Foo.exe',
        own: false,
        windowClass: 'FooWindow',
        caption: false,
        window: screen,
        client: screen,
        monitor: screen,
        minimized: false,
        dpi: 144,
      ),
      null,
      null,
    ]);
    expect(calls, isEmpty);
  });
}
