import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/mic_meter.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:hubbub/ui/user_panel.dart';

import 'support/fakes.dart';

const _mic1 = MediaDeviceInfo('m1', 'Blue Yeti', DeviceKind.audioInput);
const _mic2 = MediaDeviceInfo('m2', 'Headset Mic', DeviceKind.audioInput);
const _spk1 = MediaDeviceInfo('s1', 'Desk Speakers', DeviceKind.audioOutput);
const _spk2 = MediaDeviceInfo('s2', 'Monitor', DeviceKind.audioOutput);

void main() {
  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;
  late DevicePrefsStore devStore;
  late AudioPrefsStore audioStore;
  final bob = memberIdFor('bbbb');
  final carol = memberIdFor('cccc');

  Future<void> pumpShell(WidgetTester tester,
      {DevicePrefs? saved, AudioPrefs? audio}) async {
    events = StreamController<AppNodeEvent>.broadcast();
    final me = member('aaaa', 'Shawn');
    node = FakeNode(
        events: events,
        me: me,
        roster: [me, member('bbbb', 'Bob'), member('cccc', 'Carol')]);
    room = FakeRoom()
      ..devices = [_mic1, _mic2, _spk1, _spk2]
      ..onConnect = [
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true),
        RoomParticipant(id: bob, name: 'Bob', speaking: false, isLocal: false),
        RoomParticipant(id: carol, name: 'Carol', speaking: false, isLocal: false),
      ];
    devStore = DevicePrefsStore.memory(saved);
    audioStore = AudioPrefsStore.memory(audio);
    addTearDown(() async {
      node.dispose();
      await events.close();
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: HomePage(
        controller: node,
        room: room,
        deviceStore: devStore,
        audioStore: audioStore,
        loadConfig: () => throw StateError('a started node needs no config'),
      ),
    ));
    events.add(AppNodeEvent.hostChanged(host: node.me.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Finder f) async {
    await tester.tapAt(tester.getCenter(f), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  Finder inPanel(String tooltip) =>
      find.descendant(of: find.byType(UserPanel), matching: find.byTooltip(tooltip));

  Future<void> join(WidgetTester tester) async {
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
  }

  /// Taps a slider at [fraction] of its width (0 to 1) and lets go.
  Future<void> setSlider(WidgetTester tester, Finder slider, double fraction) async {
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + rect.width * fraction, rect.center.dy));
    await tester.pumpAndSettle();
  }

  Finder radioOn(String label) => find.descendant(
      of: find.byKey(Key('menu-item:$label')), matching: find.byIcon(Icons.radio_button_checked));

  group('mic menu', () {
    testWidgets('right_click_lists_the_inputs_with_the_current_one_checked', (tester) async {
      await pumpShell(tester, saved: const DevicePrefs(input: DeviceChoice('m2', 'Headset Mic')));
      await rightClick(tester, inPanel('Mute'));
      expect(find.text('INPUT DEVICE'), findsOneWidget);
      expect(find.byKey(const Key('menu-item:Default')), findsOneWidget);
      expect(find.byKey(const Key('menu-item:Blue Yeti')), findsOneWidget);
      expect(radioOn('Headset Mic'), findsOneWidget);
      expect(radioOn('Default'), findsNothing);
      expect(radioOn('Blue Yeti'), findsNothing);
      expect(find.text('Voice Settings'), findsOneWidget);
      // Output devices belong to the headphones menu.
      expect(find.byKey(const Key('menu-item:Desk Speakers')), findsNothing);
    });

    testWidgets('a_left_click_still_just_toggles_mute_and_opens_no_menu', (tester) async {
      await pumpShell(tester);
      await tester.tap(inPanel('Mute'));
      await tester.pumpAndSettle();
      expect(find.text('INPUT DEVICE'), findsNothing);
      expect(inPanel('Unmute'), findsOneWidget);
    });

    testWidgets('choosing_an_input_takes_the_same_path_as_settings_and_closes_the_menu',
        (tester) async {
      await pumpShell(tester);
      await join(tester);
      room.deviceCalls.clear();
      room.calls.clear();
      await rightClick(tester, inPanel('Mute'));
      await tester.tap(find.byKey(const Key('menu-item:Blue Yeti')));
      await tester.pumpAndSettle();
      expect(room.deviceCalls, ['input:m1']);
      expect(room.calls, isEmpty, reason: 'a live switch, no rejoin or mute call');
      expect(find.text('INPUT DEVICE'), findsNothing);
      expect((await devStore.load()).input!.label, 'Blue Yeti');
      await rightClick(tester, inPanel('Mute'));
      expect(radioOn('Blue Yeti'), findsOneWidget);
    });

    testWidgets('voice_settings_opens_user_settings_on_voice_and_video', (tester) async {
      await pumpShell(tester);
      await rightClick(tester, inPanel('Mute'));
      await tester.tap(find.text('Voice Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-input')), findsOneWidget);
      expect(find.text('USER SETTINGS'), findsOneWidget);
    });
  });

  group('headphones menu', () {
    testWidgets('lists_outputs_with_the_current_checked_and_a_volume_slider', (tester) async {
      await pumpShell(tester, saved: const DevicePrefs(output: DeviceChoice('s2', 'Monitor')));
      await rightClick(tester, inPanel('Deafen'));
      expect(find.text('OUTPUT DEVICE'), findsOneWidget);
      expect(radioOn('Monitor'), findsOneWidget);
      expect(find.byKey(const Key('menu-item:Desk Speakers')), findsOneWidget);
      expect(find.text('OUTPUT VOLUME'), findsOneWidget);
      expect(find.byKey(const Key('menu-output-volume')), findsOneWidget);
      expect(find.text('Voice Settings'), findsOneWidget);
    });

    testWidgets('a_failed_output_switch_from_the_menu_reverts_and_says_so_in_settings',
        (tester) async {
      await pumpShell(tester);
      room.outputError = StateError('Not found device id');
      await rightClick(tester, inPanel('Deafen'));
      await tester.tap(find.byKey(const Key('menu-item:Desk Speakers')));
      await tester.pumpAndSettle();
      expect((await devStore.load()).output, isNull);
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice & Video'));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(Dialog),
              matching: find.text("Couldn't switch to Desk Speakers. Still using Default.")),
          findsOneWidget);
    });

    testWidgets('the_output_volume_slider_sets_the_master_volume_and_saves_it', (tester) async {
      await pumpShell(tester);
      await rightClick(tester, inPanel('Deafen'));
      expect(find.text('100%'), findsOneWidget);
      await setSlider(tester, find.byKey(const Key('menu-output-volume')), 0.75);
      // 0 to 200% across the track: three quarters of the way is about 150%.
      expect(room.masterVolume, closeTo(1.5, 0.1));
      expect(find.text('${(room.masterVolume * 100).round()}%'), findsOneWidget);
      expect((await audioStore.load()).master, room.masterVolume);
    });

    testWidgets('the_track_gain_is_master_times_the_persons_own_volume', (tester) async {
      await pumpShell(tester, audio: AudioPrefs(master: 1.5, volumes: {bob: 0.5}));
      expect(room.effectiveFor(bob), closeTo(0.75, 1e-9));
      expect(room.effectiveFor(carol), closeTo(1.5, 1e-9));
    });

    testWidgets('settings_has_an_output_volume_slider_next_to_the_output_device',
        (tester) async {
      await pumpShell(tester);
      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice & Video'));
      await tester.pumpAndSettle();
      expect(find.text('OUTPUT VOLUME'), findsOneWidget);
      await setSlider(tester, find.byKey(const Key('settings-output-volume')), 0.25);
      expect(room.masterVolume, closeTo(0.5, 0.1));
    });
  });

  group('menu robustness', () {
    testWidgets('a_long_device_list_scrolls_instead_of_overflowing', (tester) async {
      await pumpShell(tester);
      room.plugDevices([
        for (var i = 0; i < 40; i++) MediaDeviceInfo('m$i', 'Mic number $i', DeviceKind.audioInput),
      ]);
      await tester.pumpAndSettle();
      await rightClick(tester, inPanel('Mute'));
      expect(tester.takeException(), isNull);
      expect(find.text('Voice Settings'), findsOneWidget);
      final menu = find.byType(SingleChildScrollView);
      expect(menu, findsWidgets);
    });

    testWidgets('a_failed_switch_from_the_menu_shows_the_error_where_you_clicked',
        (tester) async {
      await pumpShell(tester);
      room.outputError = StateError('Not found device id');
      await rightClick(tester, inPanel('Deafen'));
      await tester.tap(find.byKey(const Key('menu-item:Desk Speakers')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text("Couldn't switch to Desk Speakers. Still using Default."), findsOneWidget);
    });

    testWidgets('a_keyboard_change_of_a_slider_is_saved_too', (tester) async {
      await pumpShell(tester);
      await rightClick(tester, inPanel('Deafen'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab); // focus the slider
      await tester.pump();
      final before = room.masterVolume;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(room.masterVolume, greaterThan(before));
      expect((await audioStore.load()).master, room.masterVolume);
    });
  });

  group('per-user menu', () {
    testWidgets('right_click_on_a_voice_row_has_volume_and_local_mute_for_that_person_only',
        (tester) async {
      await pumpShell(tester);
      await join(tester);
      await rightClick(tester, find.byKey(ValueKey('voice:$bob')));
      expect(find.text('User Volume'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);
      await setSlider(tester, find.byKey(const Key('user-volume')), 0.25);
      expect(room.userVolumes[bob], closeTo(0.5, 0.1));
      expect(room.userVolumes.containsKey(carol), isFalse);
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
      expect(room.localMutes, {bob});
      expect(room.effectiveFor(bob), 0);
      expect(room.effectiveFor(carol), 1);
      final saved = await audioStore.load();
      expect(saved.muted, {bob});
      expect(saved.volumes[bob], closeTo(0.5, 0.1));
    });

    testWidgets('the_stage_tile_opens_the_same_menu_and_unmute_restores_the_volume',
        (tester) async {
      await pumpShell(tester, audio: AudioPrefs(volumes: {bob: 0.5}, muted: {bob}));
      await join(tester);
      await rightClick(tester, find.byKey(ValueKey('tile:$bob')));
      expect(find.text('User Volume'), findsOneWidget);
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
      expect(room.localMutes, isEmpty);
      expect(room.effectiveFor(bob), closeTo(0.5, 1e-9));
      expect((await audioStore.load()).muted, isEmpty);
    });

    testWidgets('the_member_list_opens_it_too', (tester) async {
      await pumpShell(tester);
      await join(tester);
      events.add(AppNodeEvent.peerUp(member: carol, direct: true));
      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.byKey(ValueKey('member:$carol')));
      expect(find.text('User Volume'), findsOneWidget);
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
      expect(room.localMutes, {carol});
    });

    testWidgets('an_offline_member_has_no_volume_menu', (tester) async {
      await pumpShell(tester);
      await join(tester);
      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();
      await rightClick(tester, find.byKey(ValueKey('member:$carol')));
      expect(find.text('User Volume'), findsNothing);
    });

    testWidgets('there_is_no_menu_on_yourself', (tester) async {
      await pumpShell(tester);
      await join(tester);
      await rightClick(tester, find.byKey(ValueKey('voice:${node.me.id}')));
      expect(find.text('User Volume'), findsNothing);
      await rightClick(tester, find.byKey(ValueKey('tile:${node.me.id}')));
      expect(find.text('User Volume'), findsNothing);
    });

    testWidgets('levels_are_applied_again_after_a_rejoin_following_a_host_change',
        (tester) async {
      await pumpShell(tester, audio: AudioPrefs(master: 0.5, volumes: {bob: 0.5}, muted: {carol}));
      await join(tester);
      // The new host's media room starts with nothing set.
      room.masterVolume = 1;
      room.userVolumes.clear();
      room.localMutes.clear();
      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(node.credentialRequests, ['lobby', 'lobby']);
      expect(room.effectiveFor(bob), closeTo(0.25, 1e-9));
      expect(room.effectiveFor(carol), 0);
    });
  });

  group('mic meter', () {
    Future<void> openVoice(WidgetTester tester) async {
      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice & Video'));
      await tester.pumpAndSettle();
    }

    double fill(WidgetTester tester) =>
        tester.widget<FractionallySizedBox>(find.byKey(const Key('mic-level'))).widthFactor!;

    testWidgets('out_of_a_call_it_says_to_join_instead_of_faking_a_level', (tester) async {
      await pumpShell(tester);
      await openVoice(tester);
      expect(find.text('Join a voice channel to test your mic'), findsOneWidget);
      expect(find.byKey(const Key('mic-level')), findsNothing);
    });

    testWidgets('in_a_call_the_adapters_level_stream_drives_the_bar', (tester) async {
      await pumpShell(tester);
      await join(tester);
      await openVoice(tester);
      expect(find.text('Join a voice channel to test your mic'), findsNothing);
      room.emitLevel(0.04);
      await tester.pump();
      final low = fill(tester);
      room.emitLevel(0.5);
      await tester.pump();
      expect(fill(tester), greaterThan(low));
      expect(fill(tester), meterFill(0.5));
      expect(find.byKey(const Key('mic-clipping')), findsNothing);
    });

    testWidgets('a_sustained_full_scale_level_shows_the_red_clipping_state', (tester) async {
      await pumpShell(tester);
      await join(tester);
      await openVoice(tester);
      for (var i = 0; i < 3; i++) {
        room.emitLevel(1);
        await tester.pump();
      }
      expect(find.byKey(const Key('mic-clipping')), findsNothing, reason: 'a short peak is fine');
      for (var i = 0; i < 6; i++) {
        room.emitLevel(1);
        await tester.pump();
      }
      expect(find.byKey(const Key('mic-clipping')), findsOneWidget);
      expect(find.textContaining('clipping'), findsOneWidget);
      room.emitLevel(0.2);
      await tester.pump();
      expect(find.byKey(const Key('mic-clipping')), findsNothing);
    });

    testWidgets('the_level_is_logged_once_a_second_for_tuning', (tester) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (m, {wrapWidth}) => lines.add(m ?? '');
      try {
        await pumpShell(tester);
        await join(tester);
        await openVoice(tester);
        for (var i = 0; i < 25; i++) {
          room.emitLevel(0.42);
          await tester.pump();
        }
      } finally {
        debugPrint = old;
      }
      expect(lines.where((l) => l == 'hubbub: micLevel 0.42').length, 3,
          reason: lines.join('|')); // samples 1, 11, 21
    });

    test('the_detector_needs_a_run_of_near_full_scale_samples', () {
      final d = ClipDetector();
      final seen = [for (final l in [1.0, 1.0, 0.3, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.1]) d.add(l)];
      expect(seen, [false, false, false, false, false, false, false, false, true, false]);
    });
  });
}
