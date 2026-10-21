import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/overlay/overlay_renderer.dart';

void main() {
  testWidgets('renders_at_physical_size_with_premultiplied_rgba', (tester) async {
    final bmp = (await tester.runAsync(() => renderOverlayImage(
        const SizedBox(width: 40, height: 20, child: ColoredBox(color: Color(0x80FF0000))),
        pixelRatio: 1.5)))!;
    expect((bmp.width, bmp.height), (60, 30));
    expect(bmp.rgba.length, 60 * 30 * 4);
    expect(bmp.rgba.sublist(0, 4), [closeTo(128, 1), 0, 0, closeTo(128, 1)]); // premultiplied
  });

  testWidgets('uncovered_pixels_are_fully_transparent', (tester) async {
    final bmp = (await tester.runAsync(() => renderOverlayImage(
        const SizedBox(
          width: 20,
          height: 20,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 10, height: 10, child: ColoredBox(color: Color(0xFF00FF00))),
          ),
        ),
        pixelRatio: 1)))!;
    expect((bmp.width, bmp.height), (20, 20));
    expect(bmp.rgba[(15 * 20 + 15) * 4 + 3], 0);
    expect(bmp.rgba[(5 * 20 + 5) * 4 + 3], 255); // the box itself is drawn
  });

  testWidgets('the_size_follows_the_content', (tester) async {
    final bmp = (await tester.runAsync(() => renderOverlayImage(
        const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 30, height: 10, child: ColoredBox(color: Color(0xFF0000FF))),
          SizedBox(width: 30, height: 10, child: ColoredBox(color: Color(0xFF0000FF))),
        ]),
        pixelRatio: 1)))!;
    expect((bmp.width, bmp.height), (60, 10));
  });
}
