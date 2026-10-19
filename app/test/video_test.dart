import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

void main() {
  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;
  late AppMember me;

  Future<void> pumpShell(WidgetTester tester, {DevicePrefs prefs = const DevicePrefs()}) async {
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
}
