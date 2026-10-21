import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/overlay/overlay_prefs.dart';
import 'package:hubbub/overlay/overlay_scene.dart';
import 'package:hubbub/overlay/overlay_view.dart';
import 'package:hubbub/ui/avatar.dart';
import 'package:hubbub/ui/channel_sidebar.dart';

import 'support/fakes.dart';
import 'support/fonts.dart';

void main() {
  setUpAll(() async {
    if (!kIsWeb) await loadAppFonts();
  });

  final me = VoiceMember(id: memberIdFor('ad27'), name: 'Shawn', isMe: true, speaking: true);
  final maya = VoiceMember(id: memberIdFor('b371'), name: 'Maya', muted: true);
  final theo = VoiceMember(id: memberIdFor('c149'), name: 'Theo', muted: true, deafened: true);
  final priya = VoiceMember(id: memberIdFor('deeb'), name: 'Priya', speaking: true);
  final members = [me, maya, theo, priya];

  OverlayRow row(String name, {bool speaking = false, bool muted = false, bool deafened = false, bool showName = true}) =>
      OverlayRow(id: memberIdFor('aaaa'), name: name, speaking: speaking, muted: muted, deafened: deafened, showName: showName);

  OverlayScene scene(List<OverlayRow> rows, {OverlayAvatarSize size = OverlayAvatarSize.large, double ratio = 1}) =>
      OverlayScene(rows: rows, avatarSize: size, pixelRatio: ratio);

  Widget host(OverlayScene s) => Directionality(textDirection: TextDirection.ltr, child: GameOverlayView(scene: s));

  group('overlayRows', () {
    test('rows_follow_the_member_order_and_include_me', () {
      final rows = overlayRows(members, const OverlayPrefs());
      expect(rows.map((r) => r.id), members.map((m) => m.id));
    });

    test('users_while_speaking_lists_only_speakers', () {
      final rows = overlayRows(members, const OverlayPrefs(users: OverlayUsers.whileSpeaking));
      expect(rows.map((r) => r.id), [me.id, priya.id]);
    });

    test('names_while_speaking_shows_only_speaking_names', () {
      final rows = overlayRows(members, const OverlayPrefs(names: OverlayNames.whileSpeaking));
      for (final r in rows) {
        expect(r.showName, r.speaking, reason: r.name);
      }
    });

    test('names_never_hides_every_name', () {
      final rows = overlayRows(members, const OverlayPrefs(names: OverlayNames.never));
      expect(rows.any((r) => r.showName), isFalse);
    });

    test('mute_and_deafen_carry_over', () {
      final rows = overlayRows(members, const OverlayPrefs());
      expect((rows[1].muted, rows[1].deafened), (true, false));
      expect((rows[2].muted, rows[2].deafened), (true, true));
      expect((rows[0].muted, rows[0].deafened), (false, false));
    });

    test('rows and scenes compare by value', () {
      expect(row('A'), row('A'));
      expect(row('A').hashCode, row('A').hashCode);
      expect(scene([row('A')]), scene([row('A')]));
      expect(scene([row('A')]).hashCode, scene([row('A')]).hashCode);
      expect(scene([row('A')]), isNot(scene([row('B')])));
      expect(scene([row('A')]), isNot(scene([row('A')], ratio: 2)));
    });
  });

  group('GameOverlayView', () {
    testWidgets('a_quiet_row_is_dimmed_and_a_speaking_row_is_not', (tester) async {
      final quiet = row('Quiet');
      await tester.pumpWidget(host(scene([quiet])));
      expect(tester.widget<Opacity>(find.descendant(of: find.byKey(Key('overlay-row:${quiet.id}')), matching: find.byType(Opacity))).opacity, 0.6);
      expect(tester.widget<Avatar>(find.byType(Avatar)).speaking, isFalse);

      await tester.pumpWidget(host(scene([row('Loud', speaking: true)])));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
      expect(tester.widget<Avatar>(find.byType(Avatar)).speaking, isTrue);
    });

    testWidgets('muted_shows_a_crossed_mic_and_deafened_adds_headphones', (tester) async {
      await tester.pumpWidget(host(scene([row('M', muted: true)])));
      expect(tester.widgetList<CrossedIcon>(find.byType(CrossedIcon)).map((c) => c.icon), [Icons.mic_rounded]);

      await tester.pumpWidget(host(scene([row('D', muted: true, deafened: true)])));
      expect(tester.widgetList<CrossedIcon>(find.byType(CrossedIcon)).map((c) => c.icon),
          [Icons.mic_rounded, Icons.headphones_rounded]);
    });

    testWidgets('a_hidden_name_leaves_only_the_avatar_unless_muted', (tester) async {
      await tester.pumpWidget(host(scene([row('Hidden', showName: false)])));
      expect(find.byType(Text).evaluate().where((e) => e.widget is Text && (e.widget as Text).data == 'Hidden'), isEmpty);
      expect(find.byType(CrossedIcon), findsNothing);
      expect(find.byType(DecoratedBox).evaluate().where((e) => (e.widget as DecoratedBox).decoration is BoxDecoration &&
          ((e.widget as DecoratedBox).decoration as BoxDecoration).color == OverlayLook.tagColor), isEmpty);

      await tester.pumpWidget(host(scene([row('Hidden', showName: false, muted: true)])));
      expect(find.text('Hidden'), findsNothing);
      expect(find.byType(CrossedIcon), findsOneWidget);
    });

    testWidgets('a_long_name_ellipsizes_at_the_tag_limit', (tester) async {
      await tester.pumpWidget(host(scene([row('W' * 60)])));
      final tag = find.ancestor(of: find.text('W' * 60), matching: find.byType(Container)).first;
      expect(tester.getSize(tag).width, lessThanOrEqualTo(OverlayLook.maxTagWidth));
      expect(tester.getSize(tag).width, OverlayLook.maxTagWidth);
    });

    testWidgets('sizes_follow_the_avatar_setting', (tester) async {
      await tester.pumpWidget(host(scene([row('A')])));
      expect(tester.widget<Avatar>(find.byType(Avatar)).size, 32);
      await tester.pumpWidget(host(scene([row('A')], size: OverlayAvatarSize.small)));
      expect(tester.widget<Avatar>(find.byType(Avatar)).size, 24);
    });

    testWidgets('rasterize_scene_is_the_view_at_the_scene_ratio', (tester) async {
      final a = OverlayRow(id: memberIdFor('aaaa'), name: 'A', speaking: true, muted: false, deafened: false, showName: false);
      final b = OverlayRow(id: memberIdFor('bbbb'), name: 'B', speaking: false, muted: false, deafened: false, showName: false);
      final bitmap = await tester.runAsync(() => rasterizeScene(scene([a, b], ratio: 1.5)));
      expect(bitmap!.height, ((2 * 32 + 4) * 1.5).ceil());
      expect(bitmap.rgba.length, bitmap.width * bitmap.height * 4);
    });
  });

  group('goldens', () {
    Future<void> golden(WidgetTester tester, OverlayAvatarSize size, String file) async {
      tester.view.physicalSize = const Size(320, 180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = overlayRows(members, OverlayPrefs(avatarSize: size));
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: const Key('golden'),
          child: Container(
            padding: const EdgeInsets.all(16),
            alignment: Alignment.topLeft,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFBFD4E6), Color(0xFF3D5A3D)],
              ),
            ),
            child: GameOverlayView(scene: scene(rows, size: size)),
          ),
        ),
      ));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(file));
    }

    testWidgets('golden_overlay_large', (tester) => golden(tester, OverlayAvatarSize.large, 'goldens/overlay_large.png'), skip: kIsWeb);
    testWidgets('golden_overlay_small', (tester) => golden(tester, OverlayAvatarSize.small, 'goldens/overlay_small.png'), skip: kIsWeb);
  });
}
