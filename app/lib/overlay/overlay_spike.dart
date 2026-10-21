import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ui/avatar.dart';
import '../ui/theme.dart';
import 'overlay_renderer.dart';

/// TEMPORARY (Task 7 deletes it): proves the overlay draws while the main window is hidden.
/// Once a second for two minutes it renders a test bubble whose ring alternates and whose tag
/// counts ticks and shows the previous tick's render-plus-send time, then sends it to the
/// overlay window, placing that at physical (100, 100) on the first tick.
/// Run with HUBBUB_OVERLAY_SPIKE=1.
Future<void> runOverlaySpike({MethodChannel channel = const MethodChannel('dev.hubbub/overlay')}) async {
  var lastMs = 0;
  for (var n = 0; n < 120; n++) {
    final watch = Stopwatch()..start();
    final bmp = await renderOverlayImage(_bubble(n, lastMs),
        pixelRatio: WidgetsBinding.instance.platformDispatcher.implicitView!.devicePixelRatio);
    await channel.invokeMethod<void>('setImage', {'rgba': bmp.rgba, 'width': bmp.width, 'height': bmp.height});
    lastMs = watch.elapsedMilliseconds;
    if (n == 0) await channel.invokeMethod<void>('place', {'x': 100, 'y': 100});
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

Widget _bubble(int n, int lastMs) => Row(mainAxisSize: MainAxisSize.min, children: [
      Avatar(id: 'ad27', name: 'Spike', size: 32, speaking: n.isOdd, background: const Color(0x00000000)),
      const SizedBox(width: 6),
      DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xB31E1F22), borderRadius: BorderRadius.circular(4)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text('spike $n · $lastMs ms',
              style: const TextStyle(
                  fontFamily: hubFont, fontSize: 14, fontWeight: FontWeight.w600, color: HubColors.white)),
        ),
      ),
    ]);
