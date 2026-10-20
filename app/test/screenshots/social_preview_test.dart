import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/ui/theme.dart';

import '../support/fonts.dart';

/// Builds docs/brand/social-preview.png (1280x640) from the logo and docs/screenshots/hero.png.
/// Run readme_screens_test.dart first. Skipped unless `--dart-define=SCREENSHOTS=true`.
const _enabled = bool.fromEnvironment('SCREENSHOTS');

Future<ui.Image> _load(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  return (await codec.getNextFrame()).image;
}

void _text(Canvas c, String s, Offset at, double size, FontWeight w, Color color, {double? width}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s, style: TextStyle(fontFamily: hubFont, fontSize: size, fontWeight: w, color: color, height: 1.1)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width ?? double.infinity);
  tp.paint(c, at);
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('social_preview', (tester) async {
    await tester.runAsync(() async {
      final icon = await _load('../docs/brand/hubbub-icon.png');
      final hero = await _load('../docs/screenshots/hero.png');
      // The logo sits on its own cobalt: use its corner colour as the background.
      final px = (await icon.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final bg = Color.fromARGB(255, px.getUint8(16), px.getUint8(17), px.getUint8(18));
      const cream = Color(0xFFFFF6E5);

      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 1280, 640), Paint()..color = bg);

      c.drawImageRect(icon, Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
          const Rect.fromLTWH(48, 56, 270, 270), Paint()..filterQuality = FilterQuality.high);
      _text(c, 'Hubbub', const Offset(348, 62), 96, FontWeight.w700, cream);
      _text(c, 'Voice, video and screen share with your friends.', const Offset(350, 182), 31, FontWeight.w600, cream);
      _text(c, 'Free. Open source. No servers, no accounts.', const Offset(350, 238), 23, FontWeight.w400,
          cream.withValues(alpha: 0.85));
      _text(c, 'Windows   |   macOS   |   Linux', const Offset(56, 566), 24, FontWeight.w600,
          cream.withValues(alpha: 0.9));

      // The hero shot, cropped to the call and the shared screen, tucked off the lower right.
      const frame = Size(740, 556);
      c.save();
      c.translate(560 + frame.width / 2, 340 + frame.height / 2);
      c.rotate(-0.045);
      final rr = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: frame.width, height: frame.height), const Radius.circular(18));
      c.drawRRect(rr.shift(const Offset(0, 14)),
          Paint()..color = const Color(0x66000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22));
      c.save();
      c.clipRRect(rr);
      c.drawImageRect(hero, const Rect.fromLTWH(346, 40, 1254, 940),
          Rect.fromCenter(center: Offset.zero, width: frame.width, height: frame.height),
          Paint()..filterQuality = FilterQuality.high);
      c.restore();
      c.drawRRect(rr, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = cream.withValues(alpha: 0.9));
      c.restore();

      final img = await rec.endRecording().toImage(1280, 640);
      final png = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      File('../docs/brand/social-preview.png').writeAsBytesSync(png.buffer.asUint8List());
    });
  }, skip: !_enabled);
}
