import 'package:flutter/material.dart';

import 'theme.dart';

/// A member id's short tag, as the core makes it: the first 4 hex characters, uppercase.
String shortTag(String memberId) =>
    memberId.substring(0, memberId.length < 4 ? memberId.length : 4).toUpperCase();

/// The avatar colour of [memberId], one of six, stable for the same id.
Color avatarColor(String memberId) {
  var h = 0;
  for (final c in memberId.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HubColors.avatars[h % HubColors.avatars.length];
}

enum Presence { online, offline }

/// A circle with the first letter of [name] on the member's colour, optionally with a
/// speaking ring and a presence dot cut out of [background].
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.id,
    required this.name,
    required this.size,
    this.speaking = false,
    this.presence,
    this.background = HubColors.sidebar,
  });

  final String id;
  final String name;
  final double size;
  final bool speaking;
  final Presence? presence;

  /// What the ring gap and the dot's cut-out show: the surface under the avatar.
  final Color background;

  @override
  Widget build(BuildContext context) {
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: avatarColor(id), shape: BoxShape.circle),
      child: Text(
        letter,
        style: TextStyle(
          fontFamily: hubFont,
          fontSize: size * 0.45,
          height: 1,
          fontWeight: FontWeight.w600,
          color: HubColors.white,
        ),
      ),
    );
    if (speaking) {
      // Discord's speaking ring: green on the rim, a hairline of background inside it.
      face = Stack(children: [
        face,
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: HubColors.green, width: size >= 64 ? 3 : 2),
            ),
            child: Padding(
              padding: EdgeInsets.all(size >= 64 ? 3 : 2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: background, width: 1),
                ),
              ),
            ),
          ),
        ),
      ]);
    }
    final p = presence;
    if (p == null) return SizedBox(width: size, height: size, child: face);
    final dot = (size * 0.3125).roundToDouble(); // 10 px on a 32 px avatar
    final cut = dot + 6;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        face,
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            width: cut,
            height: cut,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: background, shape: BoxShape.circle),
            child: Container(
              width: dot,
              height: dot,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p == Presence.online ? HubColors.green : HubColors.glyph,
                shape: BoxShape.circle,
              ),
              child: p == Presence.offline
                  ? Container(
                      width: dot / 2,
                      height: dot / 2,
                      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
                    )
                  : null,
            ),
          ),
        ),
      ]),
    );
  }
}

/// The host's crown, drawn here (Material has none), with the tooltip "Hosting".
class HostCrown extends StatelessWidget {
  const HostCrown({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Hosting',
        child: CustomPaint(size: Size(size, size), painter: _CrownPainter()),
      );
}

class _CrownPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final crown = Path()
      ..moveTo(w * 0.08, h * 0.30)
      ..lineTo(w * 0.32, h * 0.52)
      ..lineTo(w * 0.50, h * 0.18)
      ..lineTo(w * 0.68, h * 0.52)
      ..lineTo(w * 0.92, h * 0.30)
      ..lineTo(w * 0.82, h * 0.74)
      ..lineTo(w * 0.18, h * 0.74)
      ..close();
    final paint = Paint()..color = HubColors.yellow;
    canvas.drawPath(crown, paint);
    canvas.drawRRect(
        RRect.fromLTRBR(w * 0.18, h * 0.80, w * 0.82, h * 0.90, Radius.circular(h * 0.05)),
        paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// [icon] with a diagonal strike, as Discord draws a muted mic or deafened headphones.
class CrossedIcon extends StatelessWidget {
  const CrossedIcon(
    this.icon, {
    super.key,
    required this.size,
    required this.color,
    required this.strike,
    required this.background,
  });

  final IconData icon;
  final double size;
  final Color color;
  final Color strike;

  /// The surface behind the icon: the strike's outline, so it cuts through the glyph.
  final Color background;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          foregroundPainter: _StrikePainter(strike, background),
          child: Icon(icon, size: size, color: color),
        ),
      );
}

class _StrikePainter extends CustomPainter {
  _StrikePainter(this.strike, this.background);

  final Color strike;
  final Color background;

  @override
  void paint(Canvas canvas, Size s) {
    final a = Offset(s.width * 0.12, s.height * 0.12);
    final b = Offset(s.width * 0.88, s.height * 0.88);
    final w = s.width / 10;
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = background
          ..strokeWidth = w * 2.6
          ..strokeCap = StrokeCap.round);
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = strike
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_StrikePainter old) => old.strike != strike || old.background != background;
}
