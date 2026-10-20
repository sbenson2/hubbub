import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/capture_options.dart';
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

    testWidgets('in_a_call_the_post_gain_peak_drives_the_bar', (tester) async {
      await pumpShell(tester);
      await join(tester);
      await openVoice(tester);
      expect(find.text('Join a voice channel to test your mic'), findsNothing);
      room.emitPeak(0.04);
      await tester.pump();
      final low = fill(tester);
      room.emitPeak(0.5, post: 0.25);
      await tester.pump();
      expect(fill(tester), greaterThan(low));
      expect(fill(tester), meterFill(0.25), reason: 'what is sent, after the input volume');
      expect(find.byKey(const Key('mic-clipping')), findsNothing);
    });

    testWidgets('a_pre_gain_peak_at_full_scale_over_500ms_shows_the_red_clipping_state',
        (tester) async {
      await pumpShell(tester);
      await join(tester);
      await openVoice(tester);
      // quiet windows with no clipped blocks: fine, even with a big boost after the gain
      for (var i = 0; i < 12; i++) {
        room.emitPeak(0.4, post: 1, clip: 0);
        await tester.pump();
      }
      expect(find.byKey(const Key('mic-clipping')), findsNothing,
          reason: 'only the pre-gain peak counts, not what the boost makes of it');
      room.emitPeak(1, clip: 0.2); // one 10 ms block in the window reached 0.98
      await tester.pump();
      await tester.pump(); // the report lands just after the frame it was sent in
      expect(find.byKey(const Key('mic-clipping')), findsOneWidget);
      expect(find.textContaining('clipping'), findsOneWidget);
      for (var i = 0; i < 10; i++) {
        room.emitPeak(0.2);
        await tester.pump();
      }
      await tester.pump();
      expect(find.byKey(const Key('mic-clipping')), findsNothing, reason: '500 ms later it clears');
    });

    testWidgets('the_peaks_are_logged_once_a_second_for_tuning', (tester) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (m, {wrapWidth}) => lines.add(m ?? '');
      try {
        await pumpShell(tester);
        await join(tester);
        await openVoice(tester);
        for (var i = 0; i < 25; i++) {
          room.emitPeak(0.5, post: 0.42, clip: 0.0, speech: 0.9);
          await tester.pump();
        }
      } finally {
        debugPrint = old;
      }
      final mic = lines.where((l) => l.startsWith('hubbub: micLevel ')).toList();
      expect(mic.length, 2, reason: lines.join('|')); // reports 1 and 21 of twenty a second
      expect(mic.first, 'hubbub: micLevel 0.42 pre=0.5 post=0.42 clip=0.0 speech=0.9');
    });

    test('the_clip_rule_is_more_than_one_percent_of_blocks_over_500ms', () {
      final w = ClipWindow();
      // reports every 50 ms; one clipped 10 ms block in a report is 0.2 of its 5 blocks, which
      // is 2% of the 500 ms
      expect([for (var i = 0; i < 9; i++) w.add(0)], everyElement(isFalse));
      expect(w.add(0.2), isTrue);
      for (var i = 0; i < 9; i++) {
        expect(w.add(0), isTrue, reason: 'stays on while that window is inside the 500 ms');
      }
      expect(w.add(0), isFalse, reason: 'the clipped window has aged out');
      // exactly 1% is not more than 1%
      final x = ClipWindow();
      expect([for (var i = 0; i < 10; i++) x.add(i == 0 ? 0.1 : 0)].last, isFalse);
    });
  });

  group('input volume and noise suppression', () {
    Future<void> openVoice(WidgetTester tester) async {
      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice & Video'));
      await tester.pumpAndSettle();
    }

    testWidgets('the_settings_page_has_an_input_volume_slider_next_to_the_input_device',
        (tester) async {
      await pumpShell(tester);
      await openVoice(tester);
      expect(find.text('INPUT VOLUME'), findsOneWidget);
      final slider = find.byKey(const Key('settings-input-volume'));
      expect(slider, findsOneWidget);
      expect(find.descendant(of: slider, matching: find.byType(Slider)), findsOneWidget);
      expect(find.text('100%'), findsWidgets);
      await setSlider(tester, slider, 0.25); // 50% of the 0 to 200% range
      expect(room.inputGain, closeTo(0.5, 0.06));
      expect((await audioStore.load()).inputGain, closeTo(0.5, 0.06), reason: 'saved on release');
    });

    testWidgets('noise_suppression_offers_none_standard_and_rnnoise_defaulting_to_rnnoise',
        (tester) async {
      await pumpShell(tester);
      await openVoice(tester);
      expect(find.text('NOISE SUPPRESSION'), findsOneWidget);
      for (final n in NoiseSuppression.values) {
        expect(find.byKey(Key('ns-${n.name}')), findsOneWidget);
      }
      expect(find.text('None'), findsOneWidget);
      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Hubbub (RNNoise)'), findsOneWidget);
      Finder on(NoiseSuppression n) => find.descendant(
          of: find.byKey(Key('ns-${n.name}')), matching: find.byIcon(Icons.radio_button_checked));
      expect(on(NoiseSuppression.rnnoise), findsOneWidget);
      expect(on(NoiseSuppression.standard), findsNothing);
      room.micCalls.clear();
      await tester.tap(find.byKey(const Key('ns-standard')));
      await tester.pumpAndSettle();
      expect(room.micCalls, ['ns:standard']);
      expect(on(NoiseSuppression.standard), findsOneWidget);
      expect(on(NoiseSuppression.rnnoise), findsNothing);
      expect((await audioStore.load()).noiseSuppression, NoiseSuppression.standard);
    });

    testWidgets('windows_has_a_low_light_frame_rate_switch_on_by_default_that_is_saved',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await pumpShell(tester);
      expect(room.lowLightFullFrameRate, isTrue, reason: 'handed to the plugin at start');
      await openVoice(tester);
      final sw = find.byKey(const Key('low-light-full-frame-rate'));
      expect(sw, findsOneWidget);
      expect(find.text('Keep full frame rate in low light'), findsOneWidget);
      expect(find.text('Stops the webcam slowing down in dim light. The picture may be darker.'),
          findsOneWidget);
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);
      await tester.ensureVisible(sw);
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      expect(room.lowLightFullFrameRate, isFalse);
      expect((await audioStore.load()).lowLightFullFrameRate, isFalse);
      debugDefaultTargetPlatformOverride = null; // the framework checks this before tearDowns
    });

    testWidgets('the_low_light_switch_is_not_shown_off_windows', (tester) async {
      await pumpShell(tester);
      await openVoice(tester);
      expect(find.byKey(const Key('low-light-full-frame-rate')), findsNothing);
    });

    testWidgets('saved_choices_are_shown_and_given_to_the_room_at_start', (tester) async {
      await pumpShell(tester,
          audio: const AudioPrefs(inputGain: 0.5, noiseSuppression: NoiseSuppression.none));
      expect(room.inputGain, 0.5);
      expect(room.noiseSuppression, NoiseSuppression.none);
      await openVoice(tester);
      expect(
          find.descendant(
              of: find.byKey(const Key('ns-none')), matching: find.byIcon(Icons.radio_button_checked)),
          findsOneWidget);
      final slider = tester.widget<Slider>(find.descendant(
          of: find.byKey(const Key('settings-input-volume')), matching: find.byType(Slider)));
      expect(slider.value, 0.5);
    });

    testWidgets('the_mic_right_click_menu_also_has_the_input_volume_slider', (tester) async {
      await pumpShell(tester);
      await rightClick(tester, inPanel('Mute'));
      expect(find.text('INPUT VOLUME'), findsOneWidget);
      expect(find.text('OUTPUT VOLUME'), findsNothing);
      await setSlider(tester, find.byKey(const Key('menu-input-volume')), 0.75);
      expect(room.inputGain, closeTo(1.5, 0.06));
      expect((await audioStore.load()).inputGain, closeTo(1.5, 0.06));
    });

    testWidgets('the_headphones_menu_keeps_only_the_output_volume', (tester) async {
      await pumpShell(tester);
      await rightClick(tester, inPanel('Deafen'));
      expect(find.text('OUTPUT VOLUME'), findsOneWidget);
      expect(find.text('INPUT VOLUME'), findsNothing);
    });
  });
}
