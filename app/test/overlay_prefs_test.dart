import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/overlay/overlay_prefs.dart';
import 'package:hubbub/ui/settings_dialog.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

const _help = 'The overlay shows in windowed and borderless games. '
    'Some games in exclusive fullscreen need their display mode set to borderless.';

void main() {
  group('OverlayPrefs', () {
    test('defaults_are_on_large_always_always', () {
      const p = OverlayPrefs();
      expect(p.enabled, isTrue);
      expect(p.avatarSize, OverlayAvatarSize.large);
      expect(p.names, OverlayNames.always);
      expect(p.users, OverlayUsers.always);
      expect(p.toJson(), {'enabled': true, 'avatarSize': 'large', 'names': 'always', 'users': 'always'});
    });

    test('json_round_trips_and_bad_values_fall_back', () {
      const p = OverlayPrefs(
          enabled: false,
          avatarSize: OverlayAvatarSize.small,
          names: OverlayNames.never,
          users: OverlayUsers.whileSpeaking);
      expect(OverlayPrefs.fromJson(p.toJson()), p);
      expect(OverlayPrefs.fromJson({'avatarSize': 'huge', 'enabled': 'yes'}), const OverlayPrefs());
      expect(OverlayPrefs.fromJson(42), const OverlayPrefs());
    });

    test('the_file_store_saves_and_loads', () async {
      final dir = await Directory.systemTemp.createTemp('overlay-prefs');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}overlay.json';
      final store = OverlayPrefsStore.file(path);
      expect(await store.load(), const OverlayPrefs());
      const p = OverlayPrefs(enabled: false, names: OverlayNames.whileSpeaking);
      await store.save(p);
      expect(await store.load(), p);
      await File(path).writeAsString('not json {{{');
      expect(await store.load(), const OverlayPrefs());
    });

    test('update_notifies_and_saves', () async {
      final store = OverlayPrefsStore.memory();
      final settings = OverlaySettings(store);
      var calls = 0;
      settings.addListener(() => calls++);
      const p = OverlayPrefs(avatarSize: OverlayAvatarSize.small);
      await settings.update(p);
      expect(calls, 1);
      expect(settings.prefs, p);
      expect(await store.load(), p);
    });
  });

  group('Game Overlay section', () {
    Future<OverlaySettings?> open(WidgetTester tester, {bool withOverlay = true}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final overlay = withOverlay ? OverlaySettings(OverlayPrefsStore.memory()) : null;
      final room = FakeRoom();
      await tester.pumpWidget(MaterialApp(
        theme: hubbubTheme(),
        home: Scaffold(body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context,
                memberId: 'a' * 64,
                tag: 'AAAA',
                devices: DeviceSettings(room, DevicePrefsStore.memory()),
                audio: AudioSettings(room, AudioPrefsStore.memory()),
                inCall: ValueNotifier(false),
                overlay: overlay),
            child: const Text('open'),
          ),
        )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return overlay;
    }

    testWidgets('the_section_shows_only_with_overlay_settings', (tester) async {
      await open(tester);
      expect(find.text('Game Overlay'), findsOneWidget);
      Navigator.of(tester.element(find.text('Close'))).pop();
      await tester.pumpAndSettle();
      await open(tester, withOverlay: false);
      expect(find.text('Game Overlay'), findsNothing);
    });

    testWidgets('each_control_updates_the_settings_live', (tester) async {
      final overlay = (await open(tester))!;
      await tester.tap(find.text('Game Overlay'));
      await tester.pumpAndSettle();
      bool on() => tester.widget<SwitchListTile>(find.byKey(const Key('overlay-enabled'))).value;
      expect(on(), isTrue);
      expect(find.text(_help), findsOneWidget);
      await tester.tap(find.byKey(const Key('overlay-enabled')));
      await tester.pumpAndSettle();
      expect(overlay.prefs.enabled, isFalse);
      expect(on(), isFalse); // the control follows the live state
      await tester.tap(find.byKey(const Key('overlay-size-small')));
      await tester.pumpAndSettle();
      expect(overlay.prefs.avatarSize, OverlayAvatarSize.small);
      await tester.tap(find.byKey(const Key('overlay-names-whileSpeaking')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('overlay-names-never')));
      await tester.pumpAndSettle();
      expect(overlay.prefs.names, OverlayNames.never);
      await tester.tap(find.byKey(const Key('overlay-users-whileSpeaking')));
      await tester.pumpAndSettle();
      expect(overlay.prefs.users, OverlayUsers.whileSpeaking);
      expect(find.byIcon(Icons.radio_button_checked), findsNWidgets(3));
    });

    testWidgets('the_controls_follow_a_change_made_elsewhere', (tester) async {
      final overlay = (await open(tester))!;
      await tester.tap(find.text('Game Overlay'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('overlay-enabled'))).value, isTrue);
      await overlay.update(overlay.prefs.copyWith(enabled: false, users: OverlayUsers.whileSpeaking));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('overlay-enabled'))).value, isFalse);
      final row = find.descendant(
          of: find.byKey(const Key('overlay-users-whileSpeaking')), matching: find.byIcon(Icons.radio_button_checked));
      expect(row, findsOneWidget);
    });
  });
}
