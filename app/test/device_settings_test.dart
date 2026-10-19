import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:hubbub/ui/user_panel.dart';

import 'support/fakes.dart';

const _mic1 = MediaDeviceInfo('m1', 'Blue Yeti', DeviceKind.audioInput);
const _mic2 = MediaDeviceInfo('m2', 'Headset Mic', DeviceKind.audioInput);
const _spk1 = MediaDeviceInfo('s1', 'Desk Speakers', DeviceKind.audioOutput);
const _cam1 = MediaDeviceInfo('c1', 'Logitech C920', DeviceKind.videoInput);

void main() {
  group('prefs file', () {
    test('round_trips_ids_and_labels', () async {
      final dir = Directory.systemTemp.createTempSync('devprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = DevicePrefsStore.file('${dir.path}/devices.json');
      expect((await store.load()).input, isNull);
      await store.save(const DevicePrefs(
        input: DeviceChoice('m1', 'Blue Yeti'),
        output: DeviceChoice('s1', 'Desk Speakers'),
        camera: DeviceChoice('c1', 'Logitech C920'),
      ));
      final back = await DevicePrefsStore.file('${dir.path}/devices.json').load();
      expect((back.input!.id, back.input!.label), ('m1', 'Blue Yeti'));
      expect(back.output!.label, 'Desk Speakers');
      expect(back.camera!.id, 'c1');
    });

    test('a_corrupt_file_loads_as_no_choices', () async {
      final dir = Directory.systemTemp.createTempSync('devprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/devices.json').writeAsStringSync('{nope');
      expect((await DevicePrefsStore.file('${dir.path}/devices.json').load()).input, isNull);
    });

    test('matches_by_id_first_then_by_label', () {
      final list = [_mic1, _mic2];
      expect(matchDevice(const DeviceChoice('m2', 'Wrong label'), list), _mic2);
      const rebooted = DeviceChoice('old-id', 'Blue Yeti');
      expect(matchDevice(rebooted, list), _mic1);
      expect(matchDevice(const DeviceChoice('x', 'Gone'), list), isNull);
      expect(matchDevice(null, list), isNull);
    });
  });

  group('settings dialog and controller', () {
    late StreamController<AppNodeEvent> events;
    late FakeNode node;
    late FakeRoom room;
    late DevicePrefsStore store;

    Future<void> pumpShell(WidgetTester tester, {DevicePrefs? saved}) async {
      events = StreamController<AppNodeEvent>.broadcast();
      final me = member('aaaa', 'Shawn');
      node = FakeNode(events: events, me: me, roster: [me]);
      room = FakeRoom()..devices = [_mic1, _mic2, _spk1, _cam1];
      store = DevicePrefsStore.memory(saved);
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
          deviceStore: store,
          loadConfig: () => throw StateError('a started node needs no config'),
        ),
      ));
      events.add(AppNodeEvent.hostChanged(host: node.me.id, term: BigInt.one, isMe: true));
      await tester.pumpAndSettle();
    }

    Future<void> openVoiceVideo(WidgetTester tester) async {
      await tester.tap(find.byTooltip('User Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice & Video'));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String dropdown, String item) async {
      // the page is taller with the input volume and noise suppression: scroll to the dropdown
      await tester.ensureVisible(find.byKey(Key(dropdown)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(dropdown)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    testWidgets('voice_and_video_shows_three_dropdowns_with_default_first', (tester) async {
      await pumpShell(tester);
      await openVoiceVideo(tester);
      expect(find.text('INPUT DEVICE'), findsOneWidget);
      expect(find.text('OUTPUT DEVICE'), findsOneWidget);
      expect(find.text('CAMERA'), findsOneWidget);
      expect(find.text('My Account'), findsOneWidget);
      expect(find.text('Default'), findsNWidgets(3));
      await tester.tap(find.byKey(const Key('device-input')));
      await tester.pumpAndSettle();
      final items = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(DropdownMenuItem<int>), matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();
      // Closed buttons also hold their items; the open menu is the last route.
      expect(items.skip(items.length - 3), ['Default', 'Blue Yeti', 'Headset Mic']);
    });

    testWidgets('unlabelled_devices_get_a_readable_name', (tester) async {
      await pumpShell(tester);
      room.devices = const [
        MediaDeviceInfo('a', '', DeviceKind.audioInput),
        MediaDeviceInfo('b', '', DeviceKind.audioInput),
      ];
      room.plugDevices(room.devices);
      await openVoiceVideo(tester);
      await tester.tap(find.byKey(const Key('device-input')));
      await tester.pumpAndSettle();
      expect(find.text('Microphone 2'), findsOneWidget);
    });

    testWidgets('no_devices_disables_the_dropdown', (tester) async {
      await pumpShell(tester);
      room.plugDevices(const [_mic1]);
      await openVoiceVideo(tester);
      expect(find.text('No devices found'), findsNWidgets(2));
      for (final k in ['device-output', 'device-camera']) {
        final dd = tester.widget<DropdownButton<int>>(find.byKey(Key(k)));
        expect(dd.onChanged, isNull, reason: '$k is disabled');
      }
      expect(tester.widget<DropdownButton<int>>(find.byKey(const Key('device-input'))).onChanged,
          isNotNull);
    });

    testWidgets('choosing_an_input_in_a_call_asks_the_adapter_once_with_no_rejoin_and_mute_kept', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.text('lobby'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(UserPanel), matching: find.byTooltip('Mute')));
      await tester.pumpAndSettle();
      room.calls.clear();
      room.deviceCalls.clear();
      await openVoiceVideo(tester);
      await pick(tester, 'device-input', 'Headset Mic');
      expect(room.deviceCalls, ['input:m2']);
      expect(room.calls, isEmpty); // no rejoin, no mute or deafen call
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(UserPanel), matching: find.byTooltip('Unmute')),
          findsOneWidget);
    });

    testWidgets('default_follows_a_device_list_change_and_a_named_device_does_not', (tester) async {
      await pumpShell(tester);
      room.plugDevices(room.devices); // the first apply records what is in use
      await tester.pumpAndSettle();
      room.deviceCalls.clear();
      room.plugDevices([...room.devices, const MediaDeviceInfo('m3', 'USB Headset', DeviceKind.audioInput)]);
      await tester.pumpAndSettle();
      expect(room.deviceCalls, ['input:default'], reason: 'Default is re-applied for the kind that changed');

      room.deviceCalls.clear();
      room.plugDevices(room.devices); // nothing changed
      await tester.pumpAndSettle();
      expect(room.deviceCalls, isEmpty);

      await openVoiceVideo(tester);
      await pick(tester, 'device-input', 'Headset Mic');
      room.deviceCalls.clear();
      room.plugDevices([...room.devices, const MediaDeviceInfo('m4', 'Webcam Mic', DeviceKind.audioInput)]);
      await tester.pumpAndSettle();
      expect(room.deviceCalls, isEmpty, reason: 'a named, present device stays put');
    });

    testWidgets('a_failed_output_switch_reverts_the_dropdown_and_says_so', (tester) async {
      await pumpShell(tester);
      await openVoiceVideo(tester);
      room.outputError = StateError('Not found device id');
      await pick(tester, 'device-output', 'Desk Speakers');
      expect(find.text("Couldn't switch to Desk Speakers. Still using Default."), findsOneWidget);
      expect(find.text('Desk Speakers'), findsNothing);
      expect((await store.load()).output, isNull);
      room.outputError = null;
      await pick(tester, 'device-output', 'Desk Speakers');
      expect(find.textContaining("Couldn't switch"), findsNothing);
      expect((await store.load()).output!.id, 's1');
    });

    testWidgets('an_unlabelled_device_is_saved_with_its_real_empty_label', (tester) async {
      await pumpShell(tester);
      room.plugDevices(const [MediaDeviceInfo('a', '', DeviceKind.audioInput)]);
      await openVoiceVideo(tester);
      await pick(tester, 'device-input', 'Microphone 1');
      final saved = (await store.load()).input!;
      expect((saved.id, saved.label), ('a', ''));
    });

    testWidgets('choosing_default_for_the_camera_reaches_the_adapter', (tester) async {
      await pumpShell(tester);
      await openVoiceVideo(tester);
      await pick(tester, 'device-camera', 'Logitech C920');
      await pick(tester, 'device-camera', 'Default');
      expect(room.deviceCalls.where((c) => c.startsWith('camera:')).toList(),
          ['camera:c1', 'camera:default']);
    });

    testWidgets('a_choice_out_of_a_call_is_used_by_the_next_connect', (tester) async {
      await pumpShell(tester);
      await openVoiceVideo(tester);
      await pick(tester, 'device-input', 'Blue Yeti');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lobby'));
      await tester.pumpAndSettle();
      expect(room.inputAtConnect, 'm1');
      expect(room.outputId, isNull);
      expect((await store.load()).input!.label, 'Blue Yeti');
    });

    testWidgets('a_saved_device_missing_at_join_falls_back_to_default_and_is_kept',
        (tester) async {
      await pumpShell(tester, saved: const DevicePrefs(input: DeviceChoice('zz', 'Unplugged Mic')));
      await tester.tap(find.text('lobby'));
      await tester.pumpAndSettle();
      expect(room.inputAtConnect, isNull);
      expect((await store.load()).input!.label, 'Unplugged Mic');
      await openVoiceVideo(tester);
      expect(find.text('Default'), findsNWidgets(3));
      // The device comes back: the saved choice takes effect again.
      room.plugDevices([_mic1, const MediaDeviceInfo('zz', 'Unplugged Mic', DeviceKind.audioInput), _spk1]);
      await tester.pumpAndSettle();
      expect(find.text('Unplugged Mic'), findsOneWidget);
      expect(room.inputId, 'zz');
    });

    testWidgets('a_device_change_updates_the_open_dialog', (tester) async {
      await pumpShell(tester);
      await openVoiceVideo(tester);
      room.plugDevices([_mic1, _mic2, _spk1, _cam1,
          const MediaDeviceInfo('m3', 'USB Mic', DeviceKind.audioInput)]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-input')));
      await tester.pumpAndSettle();
      expect(find.text('USB Mic'), findsOneWidget);
    });
  });
}
