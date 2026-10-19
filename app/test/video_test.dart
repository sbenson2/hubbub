import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/share_sources.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

void main() {
  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;
  late AppMember me;
  late FakeShareSources shares;

  Future<void> pumpShell(WidgetTester tester, {DevicePrefs prefs = const DevicePrefs()}) async {
    shares = FakeShareSources();
    events = StreamController<AppNodeEvent>.broadcast();
    me = member('aaaa', 'Shawn');
    node = FakeNode(events: events, me: me, roster: [me, member('bbbb', 'Bob')]);
    room = FakeRoom()
      ..devices = const [MediaDeviceInfo('c1', 'Logitech C920', DeviceKind.videoInput)]
      ..onConnect = [RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true)];
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
        deviceStore: DevicePrefsStore.memory(prefs),
        shareSources: shares.load,
        loadConfig: () => throw StateError('a started node needs no config'),
      ),
    ));
    events.add(AppNodeEvent.hostChanged(host: node.me.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();
  }

  Future<void> joinLobby(WidgetTester tester) async {
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    room.calls.clear();
  }

  group('camera', () {
    testWidgets('the_camera_button_toggles_the_camera_on_the_chosen_device', (tester) async {
      await pumpShell(tester, prefs: const DevicePrefs(camera: DeviceChoice('c1', 'Logitech C920')));
      await joinLobby(tester);
      expect(room.cameraId, 'c1');

      await tester.tap(find.byTooltip('Turn On Camera'));
      await tester.pumpAndSettle();
      expect(room.calls, ['camera:true']);
      expect(find.byTooltip('Turn Off Camera'), findsOneWidget);

      await tester.tap(find.byTooltip('Turn Off Camera'));
      await tester.pumpAndSettle();
      expect(room.calls, ['camera:true', 'camera:false']);
      expect(find.byTooltip('Turn On Camera'), findsOneWidget);
    });

    testWidgets('a_participant_with_a_camera_shows_a_video_view_in_their_tile', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      expect(find.byKey(const ValueKey('video:TR_cam')), findsNothing);

      room.emitParticipants([
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true),
        RoomParticipant(
            id: 'bbbb', name: 'Bob', speaking: false, isLocal: false, camera: const VideoFeed('TR_cam')),
      ]);
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byKey(ValueKey('tile:bbbb')), matching: find.byKey(const ValueKey('video:TR_cam'))),
          findsOneWidget);
    });

    testWidgets('a_host_change_republishes_the_camera_after_reconnecting', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Turn On Camera'));
      await tester.pumpAndSettle();
      room.calls.clear();

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls, ['connect', 'mic:true', 'deafened:false', 'camera:true']);
      expect(find.byTooltip('Turn Off Camera'), findsOneWidget);
    });
  });

  group('screen share', () {
    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancelling_the_picker_shares_nothing', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await openPicker(tester);
      expect(find.text('Screens'), findsOneWidget);
      expect(find.text('Applications'), findsOneWidget);
      expect(find.text('Screen 1'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(room.calls, isEmpty);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
      expect(find.text('Go Live'), findsNothing);
    });

    testWidgets('go_live_needs_a_pick_then_publishes_that_source_and_stop_streaming_ends_it',
        (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await openPicker(tester);

      // Go Live does nothing until something is chosen.
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      expect(room.calls, isEmpty);

      await tester.tap(find.text('Applications'));
      await tester.pumpAndSettle();
      expect(find.text('Screen 1'), findsNothing);
      await tester.tap(find.text('Doom Eternal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:true:window:42:0']);
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop Streaming'));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:true:window:42:0', 'screen:false']);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('the_picker_refreshes_its_list_while_it_is_open', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await openPicker(tester);
      expect(shares.loads, 1);
      shares.sources = [
        const ShareSource(id: 'screen:0:0', name: 'Screen 1', kind: ShareKind.screen),
        const ShareSource(id: 'screen:1:0', name: 'Screen 2', kind: ShareKind.screen),
      ];
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(shares.loads, greaterThan(1));
      expect(find.text('Screen 2'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final after = shares.loads;
      await tester.pump(const Duration(seconds: 10));
      expect(shares.loads, after, reason: 'a closed picker stops polling');
    });

    testWidgets('a_desktop_without_capture_says_so_instead_of_crashing', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      shares.error = StateError('no capturer');
      await openPicker(tester);
      expect(find.text("Screen sharing isn't supported on this desktop yet"), findsOneWidget);
      expect(find.text('Go Live'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(room.calls, isEmpty);
    });

    testWidgets('a_host_change_republishes_the_share_from_the_same_source', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await openPicker(tester);
      await tester.tap(find.text('Screen 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      room.calls.clear();

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls, ['connect', 'mic:true', 'deafened:false', 'screen:true:screen:0:0']);
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);
    });
  });
}
