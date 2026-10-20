import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/hub_api.dart';
import 'package:hubbub/hub_controller.dart';
import 'package:hubbub/install.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';

import '../support/fakes.dart';
import '../support/fonts.dart';

/// Makes the README screenshots in docs/screenshots/ from the real UI and invented data.
/// It is skipped in a normal `flutter test`; run it with
///   flutter test test/screenshots/readme_screens_test.dart --dart-define=SCREENSHOTS=true
///
/// Everything on screen is made up: the people (Maya, Jonah, Priya, Theo), their ids, the
/// server, the invite link. The camera tiles and the shared screens are drawn here with
/// Canvas (flat illustrated avatars, a generic code editor and a generic route diagram):
/// no photos of anyone and nothing trademarked.
///
/// The test UI cannot render video, so a video tile is a black box. After the frame is
/// captured, each black video area is replaced by the drawn picture. Overlays that sit on
/// the video (name pills, Stream Stats, buttons) are kept and re-blended over the picture.
const _enabled = bool.fromEnvironment('SCREENSHOTS');

/// 1440x900 logical at 2x, then saved at 1600 px wide for the README.
const _logical = Size(1440, 900);
const _dpr = 2.0;
const _outWidth = 1600;

final _shotKey = GlobalKey();

// Invented people. The ids are zero padded and obviously fake.
final _maya = member('a1f3', 'Maya');
final _jonah = member('b2e4', 'Jonah');
final _priya = member('c3d5', 'Priya');
final _theo = member('d4c6', 'Theo');
final _now = DateTime(2026, 10, 17, 19, 0);

const _fakeInvite = 'hubbub://join/DEMO-ONLY-3Q7XK29F';

class _DemoHub extends FakeHub {
  _DemoHub({super.name});
  @override
  Future<String> inviteCreate(String cid, {required int expiresMin, required int maxUses}) async =>
      _fakeInvite;
}

class _DemoWindows implements WindowsSettings {
  @override
  bool startAtLogin = true;
  @override
  void setStartAtLogin(bool on) => startAtLogin = on;
  @override
  String? get version => '0.1.1';
}

/// One drawn picture for a video area.
class _Region {
  _Region(this.rect, this.paint);
  final Rect rect;
  final void Function(Canvas, Size) paint;
}

class _Dim {
  _Dim(this.rect, this.radius, this.factor);
  final Rect rect;
  final double radius;
  final double factor;
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
  });

  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;
  late _DemoHub hub;
  late HubController controller;
  late _DemoWindows windows;
  final extras = <FakeNode>[];

  AppTextMessage say(int id, AppMember who, DateTime t, String body) =>
      textMessage(from: who.id, clientId: id, at: t, body: body, seq: id);

  FakeTextService history() {
    final text = FakeTextService();
    final fri = DateTime(2026, 10, 16);
    final sat = DateTime(2026, 10, 17);
    DateTime at(DateTime d, int h, int m) => DateTime(d.year, d.month, d.day, h, m);
    var n = 0;
    AppTextMessage m(AppMember who, DateTime t, String body) => say(++n, who, t, body);
    text.history['general'] = [
      m(_priya, at(fri, 21, 4), 'me! anything after 7 works'),
      m(_priya, at(fri, 21, 4), 'and I finally fixed my mic, no more fan noise'),
      m(_theo, at(fri, 21, 9), 'I can do 8. need to finish the laundry first'),
      m(_maya, at(fri, 21, 15), '8 it is. Squad Voice, bring snacks'),
      m(_jonah, at(sat, 14, 20), "here's last week's clip, the ending is unreal"),
      m(_jonah, at(sat, 14, 20), 'https://example.com/clips/last-second-win'),
      m(_theo, at(sat, 14, 31), 'I watched it live and still do not believe it'),
      m(_maya, at(sat, 14, 35), 'framing that one. moving it to #clips'),
      m(_priya, at(sat, 15, 10), "I'll share my screen tonight so we can plan the route"),
      m(_priya, at(sat, 15, 11), 'made a map with all the stops'),
      m(_maya, at(sat, 15, 42), 'perfect. pizza first, then the run'),
      m(_theo, at(sat, 15, 50), 'pizza is non-negotiable'),
      m(_jonah, at(sat, 18, 55), 'heading to Squad Voice now, see you there'),
    ];
    return text;
  }

  // Built in each test body so the fakes' streams run in the test's zone.
  void arrange({String profile = 'Maya', bool servers = true}) {
    events = StreamController<AppNodeEvent>.broadcast();
    windows = _DemoWindows();
    node = FakeNode(
      events: events,
      me: _maya,
      roster: [_maya, _jonah, _priya, _theo],
      textChannels: const ['general', 'clips', 'plans'],
      voiceChannels: const ['Squad Voice', 'Chill Room'],
      name: 'Weekend Raid',
      text: history(),
    );
    hub = _DemoHub(name: profile);
    if (servers) {
      hub.add('c1', 'Weekend Raid', node, isOwner: true);
      for (final (cid, name) in [('c2', 'Book Club'), ('c3', 'Sunday Cooks')]) {
        final other = FakeNode(
            events: StreamController<AppNodeEvent>.broadcast(),
            me: _maya,
            roster: [_maya],
            name: name);
        extras.add(other);
        hub.add(cid, name, other);
      }
    }
    room = FakeRoom()
      ..devices = const [
        MediaDeviceInfo('mic1', 'Headset Microphone', DeviceKind.audioInput),
        MediaDeviceInfo('mic2', 'Desk Microphone', DeviceKind.audioInput),
        MediaDeviceInfo('spk1', 'Headset Speakers', DeviceKind.audioOutput),
        MediaDeviceInfo('spk2', 'Desktop Speakers', DeviceKind.audioOutput),
        MediaDeviceInfo('cam1', 'HD Webcam', DeviceKind.videoInput),
      ];
    controller = HubController(hub)..refresh();
    addTearDown(() async {
      controller.dispose();
      node.dispose();
      for (final e in extras) {
        e.dispose();
      }
      extras.clear();
      await events.close();
    });
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = _logical * _dpr;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: hubbubTheme(),
        home: HomePage(
          hub: controller,
          room: room,
          windowsSettings: windows,
          loadConfig: () => throw StateError('a hub needs no config'),
          clock: () => _now,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> everyoneOnline(WidgetTester tester) async {
    for (final p in [_jonah, _priya, _theo]) {
      events.add(AppNodeEvent.peerUp(member: p.id, direct: true));
    }
    events.add(AppNodeEvent.hostChanged(host: _maya.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();
  }

  Future<void> joinSquadVoice(WidgetTester tester) async {
    await tester.tap(find.text('Squad Voice'));
    await tester.pumpAndSettle();
  }

  // Find the black video areas and the dark overlays on them.
  _Region region(WidgetTester tester, String sid, void Function(Canvas, Size) paint) =>
      _Region(tester.getRect(find.byKey(ValueKey('video:$sid'))), paint);

  List<_Dim> dims(WidgetTester tester) {
    final out = <_Dim>[];
    final found = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      if (d is! BoxDecoration) return false;
      final c = d.color;
      return c != null && (c.toARGB32() == 0x99000000 || c.toARGB32() == 0xB3000000);
    });
    for (final e in found.evaluate()) {
      final d = (e.widget as DecoratedBox).decoration as BoxDecoration;
      final rect = tester.getRect(find.byElementPredicate((x) => x == e));
      final radius = d.shape == BoxShape.circle
          ? rect.shortestSide / 2
          : ((d.borderRadius as BorderRadius?)?.topLeft.x ?? 0);
      out.add(_Dim(rect, radius, 1 - d.color!.a));
    }
    return out;
  }

  /// Captures the frame at 2x, paints [regions], and writes a 1600 px PNG.
  Future<void> shoot(WidgetTester tester, String name, [List<_Region> regions = const []]) async {
    final overlays = dims(tester);
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
    await tester.runAsync(() async {
      final shot = await boundary.toImage(pixelRatio: _dpr);
      final w = shot.width, h = shot.height;
      var result = shot;
      if (regions.isNotEmpty) {
        final px = (await shot.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        final out = Uint8List.fromList(px);
        for (final r in regions) {
          await _composite(r, overlays, px, out, w);
        }
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(out, w, h, ui.PixelFormat.rgba8888, done.complete);
        result = await done.future;
      }
      // Scale down to the README width.
      final outH = (h * _outWidth / w).round();
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(
          result,
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Rect.fromLTWH(0, 0, _outWidth.toDouble(), outH.toDouble()),
          Paint()..filterQuality = FilterQuality.high);
      final small = await rec.endRecording().toImage(_outWidth, outH);
      final png = (await small.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('../docs/screenshots/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(png.buffer.asUint8List());
    });
  }

  Future<void> scene(String name, Future<void> Function(WidgetTester) body) async {
    testWidgets('readme_$name', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }, skip: !_enabled);
  }

  scene('welcome', (tester) async {
    arrange(profile: '', servers: false);
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField).first, 'Maya');
    await tester.pumpAndSettle();
    await shoot(tester, 'welcome');
  });

  scene('chat', (tester) async {
    arrange();
    await pumpApp(tester);
    await everyoneOnline(tester);
    await shoot(tester, 'chat');
  });

  Future<void> voiceCall(WidgetTester tester, List<RoomParticipant> people) async {
    arrange();
    room.onConnect = people;
    await pumpApp(tester);
    await everyoneOnline(tester);
    await joinSquadVoice(tester);
  }

  scene('voice', (tester) async {
    await voiceCall(tester, [
      RoomParticipant(id: _maya.id, name: 'Maya', speaking: true, isLocal: true),
      RoomParticipant(id: _jonah.id, name: 'Jonah', speaking: false, isLocal: false),
      RoomParticipant(id: _priya.id, name: 'Priya', speaking: false, isLocal: false, muted: true),
      RoomParticipant(id: _theo.id, name: 'Theo', speaking: false, isLocal: false, muted: true),
    ]);
    room.emitPeak(0.4);
    await tester.pump(const Duration(milliseconds: 100));
    await shoot(tester, 'voice');
  });

  scene('video', (tester) async {
    await voiceCall(tester, [
      RoomParticipant(
          id: _maya.id, name: 'Maya', speaking: false, isLocal: true, camera: const VideoFeed('cam_maya')),
      RoomParticipant(
          id: _jonah.id, name: 'Jonah', speaking: true, isLocal: false, camera: const VideoFeed('cam_jonah')),
      RoomParticipant(
          id: _priya.id, name: 'Priya', speaking: false, isLocal: false, camera: const VideoFeed('cam_priya')),
      RoomParticipant(
          id: _theo.id,
          name: 'Theo',
          speaking: false,
          isLocal: false,
          muted: true,
          camera: const VideoFeed('cam_theo')),
    ]);
    await shoot(tester, 'video', [
      region(tester, 'cam_maya', (c, s) => _portrait(c, s, _maya$)),
      region(tester, 'cam_jonah', (c, s) => _portrait(c, s, _jonah$)),
      region(tester, 'cam_priya', (c, s) => _portrait(c, s, _priya$)),
      region(tester, 'cam_theo', (c, s) => _portrait(c, s, _theo$)),
    ]);
  });

  /// Someone presents [kind]; Maya watches it large, with Stream Stats open.
  Future<List<_Region>> sharing(WidgetTester tester, AppMember who, _Screen kind,
      {required bool cameras}) async {
    RoomParticipant p(AppMember m, {bool speaking = false, bool muted = false, String? share}) => RoomParticipant(
        id: m.id,
        name: m.name,
        speaking: speaking,
        isLocal: m.id == _maya.id,
        muted: muted,
        camera: cameras ? VideoFeed('cam_${m.name.toLowerCase()}') : null,
        share: share == null ? null : VideoFeed(share));
    await voiceCall(tester, [
      p(_maya),
      p(_jonah, speaking: who.id != _jonah.id, share: who.id == _jonah.id ? 'share' : null),
      p(_priya, speaking: who.id == _priya.id, share: who.id == _priya.id ? 'share' : null),
      p(_theo, muted: true),
    ]);
    await tester.tap(find.text('Watch Stream'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('stream:${who.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stream Stats'));
    await tester.pumpAndSettle();
    room.emitSignal(RoomVideoRx(VideoRxSample(
        participantId: who.id,
        width: 1920,
        height: 1080,
        framesPerSecond: 48,
        kbps: 5200,
        framesDropped: 0,
        decoder: 'hardware')));
    await tester.pump(const Duration(milliseconds: 100));
    return [
      region(tester, 'share', (c, s) => kind == _Screen.editor ? _editor(c, s) : _diagram(c, s)),
      if (cameras)
        for (final (m, art) in [(_maya, _maya$), (_jonah, _jonah$), (_priya, _priya$), (_theo, _theo$)])
          region(tester, 'cam_${m.name.toLowerCase()}', (c, s) => _portrait(c, s, art)),
    ];
  }

  scene('screen-share', (tester) async {
    final regions = await sharing(tester, _jonah, _Screen.editor, cameras: false);
    await shoot(tester, 'screen-share', regions);
  });

  scene('hero', (tester) async {
    final regions = await sharing(tester, _priya, _Screen.diagram, cameras: true);
    await shoot(tester, 'hero', regions);
  });

  scene('invite', (tester) async {
    arrange();
    await pumpApp(tester);
    await everyoneOnline(tester);
    await tester.tap(find.byTooltip('Server Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite People'));
    await tester.pumpAndSettle();
    await shoot(tester, 'invite');
  });

  scene('settings', (tester) async {
    await voiceCall(tester, [
      RoomParticipant(id: _maya.id, name: 'Maya', speaking: true, isLocal: true),
      RoomParticipant(id: _jonah.id, name: 'Jonah', speaking: false, isLocal: false),
      RoomParticipant(id: _priya.id, name: 'Priya', speaking: false, isLocal: false),
      RoomParticipant(id: _theo.id, name: 'Theo', speaking: false, isLocal: false),
    ]);
    await tester.tap(find.byTooltip('User Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice & Video'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      room.emitPeak(0.35 + 0.05 * i);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await shoot(tester, 'settings');
  });
}

// ---------------------------------------------------------------------------------------
// Compositing: put a drawn picture where the test UI shows a black video box.

Future<void> _composite(_Region r, List<_Dim> overlays, Uint8List src, Uint8List dst, int width) async {
  final x0 = (r.rect.left * _dpr).round(), y0 = (r.rect.top * _dpr).round();
  final w = (r.rect.width * _dpr).round(), h = (r.rect.height * _dpr).round();
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(_dpr);
  r.paint(canvas, r.rect.size);
  final art = await rec.endRecording().toImage(w, h);
  final a = (await art.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final clip = RRect.fromRectAndRadius(
      Rect.fromLTWH(x0 + 0.5, y0 + 0.5, w - 1.0, h - 1.0), Radius.circular(8 * _dpr - 0.5));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final gx = x0 + x, gy = y0 + y;
      if (!clip.contains(Offset(gx + 0.5, gy + 0.5))) continue;
      final i = (gy * width + gx) * 4;
      final pr = src[i], pg = src[i + 1], pb = src[i + 2];
      // Only neutral pixels are black video, white text or a white icon over it.
      if ((pr - pg).abs() > 3 || (pg - pb).abs() > 3) continue;
      final cover = math.max(pr, math.max(pg, pb)) / 255;
      var under = 1.0;
      for (final d in overlays) {
        if (_inRounded(d, gx / _dpr + 0.5 / _dpr, gy / _dpr + 0.5 / _dpr)) under *= d.factor;
      }
      final j = (y * w + x) * 4;
      for (var k = 0; k < 3; k++) {
        final v = src[i + k] + a[j + k] * under * (1 - cover);
        dst[i + k] = v.round().clamp(0, 255);
      }
      dst[i + 3] = 255;
    }
  }
}

bool _inRounded(_Dim d, double x, double y) =>
    RRect.fromRectAndRadius(d.rect, Radius.circular(d.radius)).contains(Offset(x, y));

// ---------------------------------------------------------------------------------------
// Drawn pictures. Flat shapes only; nobody's likeness and no brands.

enum _Screen { editor, diagram }

class _Face {
  const _Face(this.bg1, this.bg2, this.skin, this.hair, this.shirt, this.style);
  final Color bg1, bg2, skin, hair, shirt;
  final int style; // 0 short, 1 long, 2 curly, 3 cap
}

const _maya$ = _Face(Color(0xFF3A2D6B), Color(0xFFD1649B), Color(0xFFD9A07C), Color(0xFF2B1B17), Color(0xFFF2C14E), 1);
const _jonah$ = _Face(Color(0xFF0F4C5C), Color(0xFF5FB49C), Color(0xFF8D5A3B), Color(0xFF1A1411), Color(0xFFE9ECEF), 0);
const _priya$ = _Face(Color(0xFF7B2D26), Color(0xFFF2A65A), Color(0xFFB9784F), Color(0xFF140D0B), Color(0xFF3D5A80), 1);
const _theo$ = _Face(Color(0xFF1D3557), Color(0xFF6C9BD1), Color(0xFFF0C8A5), Color(0xFF8A5A2B), Color(0xFFE76F51), 2);

void _portrait(Canvas c, Size s, _Face f) {
  final rect = Offset.zero & s;
  c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [f.bg1, f.bg2]));
  // Soft out-of-focus lights.
  final rnd = math.Random(f.style * 7 + f.skin.toARGB32());
  for (var i = 0; i < 7; i++) {
    c.drawCircle(
        Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height * 0.7),
        s.height * (0.06 + rnd.nextDouble() * 0.1),
        Paint()..color = Colors.white.withValues(alpha: 0.07 + rnd.nextDouble() * 0.06));
  }
  final cx = s.width / 2;
  final hr = s.height * 0.2;
  final headY = s.height * 0.46;
  Paint fill(Color col) => Paint()..color = col;
  // Hair behind the head.
  if (f.style == 1) {
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(cx, headY + hr * 0.9), width: hr * 2.5, height: hr * 3.2),
            Radius.circular(hr * 1.2)),
        fill(f.hair));
  }
  // Shoulders and neck.
  c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, s.height * 1.0), width: hr * 5.4, height: s.height * 0.62),
          Radius.circular(hr * 1.6)),
      fill(f.shirt));
  c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, headY + hr * 1.25), width: hr * 0.9, height: hr * 1.1),
          Radius.circular(hr * 0.3)),
      fill(Color.lerp(f.skin, Colors.black, 0.12)!));
  // Head.
  c.drawOval(Rect.fromCenter(center: Offset(cx, headY), width: hr * 1.8, height: hr * 2.1), fill(f.skin));
  // Hair on top.
  switch (f.style) {
    case 0:
      c.drawArc(Rect.fromCenter(center: Offset(cx, headY - hr * 0.1), width: hr * 1.95, height: hr * 2.3),
          math.pi, math.pi, true, fill(f.hair));
    case 1:
      c.drawArc(Rect.fromCenter(center: Offset(cx, headY - hr * 0.05), width: hr * 2.0, height: hr * 2.3),
          math.pi * 0.95, math.pi * 1.1, true, fill(f.hair));
    case 2:
      for (var i = 0; i < 7; i++) {
        final a = math.pi + i * math.pi / 6;
        c.drawCircle(Offset(cx + math.cos(a) * hr * 0.85, headY - hr * 0.05 + math.sin(a) * hr * 1.0),
            hr * 0.32, fill(f.hair));
      }
      c.drawArc(Rect.fromCenter(center: Offset(cx, headY - hr * 0.15), width: hr * 1.8, height: hr * 1.9),
          math.pi, math.pi, true, fill(f.hair));
    default:
      c.drawArc(Rect.fromCenter(center: Offset(cx, headY - hr * 0.1), width: hr * 1.95, height: hr * 2.3),
          math.pi, math.pi, true, fill(f.hair));
  }
  // A quiet face: two eyes and a smile.
  final ink = fill(const Color(0xFF2A1D18));
  c.drawCircle(Offset(cx - hr * 0.32, headY + hr * 0.05), hr * 0.07, ink);
  c.drawCircle(Offset(cx + hr * 0.32, headY + hr * 0.05), hr * 0.07, ink);
  c.drawArc(Rect.fromCenter(center: Offset(cx, headY + hr * 0.38), width: hr * 0.55, height: hr * 0.35), 0.2,
      math.pi - 0.4, false, Paint()..color = const Color(0xFF2A1D18)..style = PaintingStyle.stroke..strokeWidth = hr * 0.06..strokeCap = StrokeCap.round);
  // A little vignette.
  c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(rect.center, s.longestSide * 0.7,
            [Colors.transparent, Colors.black.withValues(alpha: 0.28)], [0.6, 1]));
}

/// A generic code editor: bars stand in for text.
void _editor(Canvas c, Size s) {
  final k = s.height / 600;
  c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF1B1E2B));
  // Title bar.
  c.drawRect(Rect.fromLTWH(0, 0, s.width, 34 * k), Paint()..color = const Color(0xFF151824));
  for (var i = 0; i < 3; i++) {
    c.drawCircle(Offset((110 + i * 20) * k, 17 * k), 6 * k,
        Paint()..color = [const Color(0xFFFF6B6B), const Color(0xFFFFD166), const Color(0xFF06D6A0)][i]);
  }
  _label(c, 'notes - weekend plan', Offset(s.width / 2 - 70 * k, 9 * k), 14 * k, const Color(0xFF8B93AB));
  // Sidebar.
  final sideW = s.width * 0.17;
  c.drawRect(Rect.fromLTWH(0, 34 * k, sideW, s.height), Paint()..color = const Color(0xFF181B28));
  final rnd = math.Random(3);
  for (var i = 0; i < 12; i++) {
    final indent = (i % 4 == 0 ? 14 : 30) * k;
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(indent, (56 + i * 26) * k, (30 + rnd.nextInt(60)) * k, 9 * k), Radius.circular(4 * k)),
        Paint()..color = i == 3 ? const Color(0xFF7AA2F7) : const Color(0xFF414868));
  }
  // Tabs.
  c.drawRect(Rect.fromLTWH(sideW, 34 * k, s.width - sideW, 32 * k), Paint()..color = const Color(0xFF151824));
  c.drawRect(Rect.fromLTWH(sideW, 34 * k, 130 * k, 32 * k), Paint()..color = const Color(0xFF1B1E2B));
  c.drawRect(Rect.fromLTWH(sideW, 34 * k, 130 * k, 2 * k), Paint()..color = const Color(0xFF7AA2F7));
  _label(c, 'route.md', Offset(sideW + 18 * k, 41 * k), 14 * k, const Color(0xFFC0CAF5));
  _label(c, 'snacks.md', Offset(sideW + 150 * k, 41 * k), 14 * k, const Color(0xFF565F89));
  // Code.
  final colors = [
    const Color(0xFFBB9AF7),
    const Color(0xFF9ECE6A),
    const Color(0xFFE0AF68),
    const Color(0xFF7AA2F7),
    const Color(0xFF7DCFFF),
    const Color(0xFF565F89),
  ];
  final codeLeft = sideW + 60 * k;
  final minimap = s.width * 0.1;
  for (var line = 0; line < 22; line++) {
    final y = (86 + line * 22) * k;
    _label(c, '${line + 1}', Offset(sideW + 22 * k, y - 4 * k), 12 * k, const Color(0xFF3B4261));
    var x = codeLeft + (line % 7 == 0 || line % 7 == 6 ? 0 : (line % 3 + 1) * 22 * k);
    final tokens = 2 + rnd.nextInt(4);
    for (var t = 0; t < tokens; t++) {
      final w = (24 + rnd.nextInt(90)) * k;
      if (x + w > s.width - minimap - 30 * k) break;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, 9 * k), Radius.circular(4 * k)),
          Paint()..color = colors[rnd.nextInt(colors.length)].withValues(alpha: 0.9));
      x += w + 8 * k;
    }
  }
  // Highlighted current line.
  c.drawRect(Rect.fromLTWH(sideW, (86 + 9 * 22) * k - 7 * k, s.width - sideW - minimap, 22 * k),
      Paint()..color = const Color(0x1A7AA2F7));
  // Minimap.
  for (var i = 0; i < 40; i++) {
    c.drawRect(Rect.fromLTWH(s.width - minimap + 8 * k, (80 + i * 8) * k, (10 + rnd.nextInt(50)) * k, 3 * k),
        Paint()..color = const Color(0x33C0CAF5));
  }
  // Status bar.
  c.drawRect(Rect.fromLTWH(0, s.height - 24 * k, s.width, 24 * k), Paint()..color = const Color(0xFF3D59A1));
  _label(c, 'Ln 10, Col 24', Offset(s.width - 130 * k, s.height - 20 * k), 12 * k, const Color(0xFFE6EBFF));
}

/// A generic route map: stops joined by lines on a soft grid.
void _diagram(Canvas c, Size s) {
  final k = s.height / 600;
  c.drawRect(
      Offset.zero & s,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(s.width, s.height),
            [const Color(0xFFF4F1E8), const Color(0xFFE4EDF0)]));
  final grid = Paint()
    ..color = const Color(0x14000000)
    ..strokeWidth = 1;
  for (var x = 0.0; x < s.width; x += 40 * k) {
    c.drawLine(Offset(x, 0), Offset(x, s.height), grid);
  }
  for (var y = 0.0; y < s.height; y += 40 * k) {
    c.drawLine(Offset(0, y), Offset(s.width, y), grid);
  }
  // A river and a park for a map feel.
  final river = Path()
    ..moveTo(0, s.height * 0.72)
    ..cubicTo(s.width * 0.25, s.height * 0.55, s.width * 0.5, s.height * 0.95, s.width, s.height * 0.62)
    ..lineTo(s.width, s.height * 0.72)
    ..cubicTo(s.width * 0.5, s.height * 1.05, s.width * 0.25, s.height * 0.65, 0, s.height * 0.82)
    ..close();
  c.drawPath(river, Paint()..color = const Color(0xFFBFDCE8));
  c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(s.width * 0.62, s.height * 0.12, s.width * 0.26, s.height * 0.26), Radius.circular(30 * k)),
      Paint()..color = const Color(0xFFCFE3C2));
  final stops = [
    Offset(s.width * 0.14, s.height * 0.3),
    Offset(s.width * 0.34, s.height * 0.2),
    Offset(s.width * 0.5, s.height * 0.42),
    Offset(s.width * 0.72, s.height * 0.3),
    Offset(s.width * 0.82, s.height * 0.55),
  ];
  final path = Path()..moveTo(stops.first.dx, stops.first.dy);
  for (var i = 1; i < stops.length; i++) {
    final a = stops[i - 1], b = stops[i];
    path.cubicTo(a.dx + (b.dx - a.dx) * 0.5, a.dy, a.dx + (b.dx - a.dx) * 0.5, b.dy, b.dx, b.dy);
  }
  c.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF3D5A80)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6 * k
        ..strokeCap = StrokeCap.round);
  const names = ['Pizza', 'Arcade', 'Start', 'Run', 'Finish'];
  for (var i = 0; i < stops.length; i++) {
    c.drawCircle(stops[i], 22 * k, Paint()..color = Colors.white);
    c.drawCircle(stops[i], 16 * k, Paint()..color = i == 2 ? const Color(0xFFE76F51) : const Color(0xFF3D5A80));
    _label(c, '${i + 1}', stops[i] - Offset(4.5 * k, 9 * k), 16 * k, Colors.white);
    final tag = RRect.fromRectAndRadius(
        Rect.fromLTWH(stops[i].dx - 36 * k, stops[i].dy + 30 * k, 72 * k, 26 * k), Radius.circular(13 * k));
    c.drawRRect(tag, Paint()..color = Colors.white.withValues(alpha: 0.92));
    _label(c, names[i], Offset(stops[i].dx - names[i].length * 3.6 * k, stops[i].dy + 35 * k), 14 * k,
        const Color(0xFF22313F));
  }
}

void _label(Canvas c, String text, Offset at, double size, Color color) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontFamily: hubFont, fontSize: size, color: color)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, at);
}
