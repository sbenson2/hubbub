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
  late List<bool> fullscreen;

  Future<void> pumpShell(WidgetTester tester, {DevicePrefs prefs = const DevicePrefs()}) async {
    shares = FakeShareSources();
    fullscreen = [];
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
        setFullscreen: (on) async => fullscreen.add(on),
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

  // Bob and Shawn in the call; [bob] and [mine] are what each has published.
  void callWith(WidgetTester tester, {VideoFeed? bobShare, VideoFeed? bobCamera, VideoFeed? myShare}) {
    room.emitParticipants([
      RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true, share: myShare),
      RoomParticipant(
          id: 'bbbb', name: 'Bob', speaking: false, isLocal: false, camera: bobCamera, share: bobShare),
    ]);
  }

  group('streams', () {
    const stream = VideoFeed('TR_s');

    testWidgets('watch_subscribes_only_on_click', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();

      // Announced, not received: a LIVE badge and a Watch Stream button, no subscription.
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('Watch Stream'), findsOneWidget);
      expect(room.calls.where((c) => c.startsWith('video:')), isEmpty);

      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('video:')).toList(), ['video:bbbb:TR_s:true']);
      expect(find.text('Watch Stream'), findsNothing);

      // Later participant updates (speaking, mute) do not subscribe again.
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('video:')).length, 1);

      await tester.tap(find.byTooltip('Stop Watching'));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('video:')).toList(),
          ['video:bbbb:TR_s:true', 'video:bbbb:TR_s:false']);
      expect(find.text('Watch Stream'), findsOneWidget);
    });

    testWidgets('a_watched_stream_is_shown_large_with_the_other_tiles_in_a_strip', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focused')), findsNothing);

      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      final big = tester.getSize(find.byKey(const ValueKey('focused')));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('focused')), matching: find.byKey(const ValueKey('video:TR_s'))),
          findsOneWidget);
      final strip = find.byKey(const ValueKey('strip'));
      expect(find.descendant(of: strip, matching: find.byKey(ValueKey('tile:${me.id}'))), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.byKey(const ValueKey('tile:bbbb'))), findsOneWidget);
      expect(big.width, greaterThan(tester.getSize(find.byKey(const ValueKey('tile:bbbb'))).width * 2));
    });

    testWidgets('your_own_share_is_a_preview_tile_labelled_as_yours_with_no_watch_button',
        (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, myShare: const VideoFeed('TR_mine'));
      await tester.pumpAndSettle();
      expect(find.text('Your stream'), findsOneWidget);
      expect(find.byKey(const ValueKey('video:TR_mine')), findsOneWidget);
      expect(find.text('Watch Stream'), findsNothing);
      expect(room.calls.where((c) => c.startsWith('video:')), isEmpty);
    });

    testWidgets('focusing_a_camera_asks_for_the_better_layer_and_closing_goes_back', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobCamera: const VideoFeed('TR_cam'));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('quality:')), isEmpty);

      await tester.tap(find.byKey(const ValueKey('tile:bbbb')));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('quality:')).toList(), ['quality:bbbb:TR_cam:high']);
      expect(find.byKey(const ValueKey('focused')), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('quality:')).toList(),
          ['quality:bbbb:TR_cam:high', 'quality:bbbb:TR_cam:low']);
      expect(find.byKey(const ValueKey('focused')), findsNothing);
    });

    testWidgets('a_host_change_resubscribes_a_watched_stream_that_still_exists', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      room.calls.clear();

      // The new host's room has Bob sharing under a new track id.
      room.onConnect = [
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true),
        RoomParticipant(
            id: 'bbbb', name: 'Bob', speaking: false, isLocal: false, share: const VideoFeed('TR_s2')),
      ];
      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('video:')).toList(), ['video:bbbb:TR_s2:true']);
      expect(find.byKey(const ValueKey('focused')), findsOneWidget);
    });

    testWidgets('a_stream_that_ends_is_forgotten_and_a_later_one_needs_a_new_click', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      room.calls.clear();

      callWith(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focused')), findsNothing);

      callWith(tester, bobShare: const VideoFeed('TR_s3'));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('video:')), isEmpty);
      expect(find.text('Watch Stream'), findsOneWidget);
    });

    testWidgets('full_screen_covers_the_window_with_the_stream_and_exits_back', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Full Screen'));
      await tester.pumpAndSettle();
      expect(fullscreen, [true]);
      expect(find.byKey(const ValueKey('fullscreen')), findsOneWidget);

      await tester.tap(find.byTooltip('Exit Full Screen'));
      await tester.pumpAndSettle();
      expect(fullscreen, [true, false]);
      expect(find.byKey(const ValueKey('fullscreen')), findsNothing);
    });
  });

  group('stats overlay', () {
    const stream = VideoFeed('TR_s');
    const sample = VideoRxSample(
        participantId: 'bbbb', width: 1920, height: 1080, framesPerSecond: 59.6, kbps: 5400.4);

    test('video_rx_line_has_the_resolution_fps_and_kbps', () {
      expect(formatVideoRx(sample), 'video_rx from=bbbb 1920x1080 fps=59.6 kbps=5400');
      expect(formatVideoRx(const VideoRxSample()), 'video_rx from=? 0x0 fps=0.0 kbps=0');
    });

    testWidgets('the_overlay_is_off_until_toggled_then_shows_what_is_received', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoRx(sample));
      await tester.pumpAndSettle();
      expect(find.text('1920x1080'), findsNothing);

      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.text('1920x1080'), findsOneWidget);
      expect(find.text('60 fps'), findsOneWidget);
      expect(find.text('5400 kbps'), findsOneWidget);

      room.emitSignal(const RoomVideoRx(VideoRxSample(
          participantId: 'bbbb', width: 1280, height: 720, framesPerSecond: 30, kbps: 2400)));
      await tester.pumpAndSettle();
      expect(find.text('1280x720'), findsOneWidget);

      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.text('1280x720'), findsNothing);
    });

    testWidgets('every_sample_is_logged_as_video_rx', (tester) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        await pumpShell(tester);
        await joinLobby(tester);
        room.emitSignal(const RoomVideoRx(sample));
        await tester.pump();
      } finally {
        debugPrint = old;
      }
      expect(lines, contains('hubbub: video_rx from=bbbb 1920x1080 fps=59.6 kbps=5400'));
    });
  });

  group('fix round 1', () {
    const stream = VideoFeed('TR_s');

    testWidgets('a_share_ended_by_the_capture_runs_the_stop_streaming_path', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Screen 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);
      room.calls.clear();

      room.emitSignal(RoomSignal.shareEnded);
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:false']);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('the_overlay_shows_the_focused_stream_not_the_latest_sample', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoRx(
          VideoRxSample(participantId: 'bbbb', width: 1920, height: 1080, framesPerSecond: 60, kbps: 5000)));
      room.emitSignal(const RoomVideoRx(
          VideoRxSample(participantId: 'cccc', width: 640, height: 360, framesPerSecond: 15, kbps: 500)));
      await tester.pumpAndSettle();
      expect(find.text('1920x1080'), findsOneWidget);
      expect(find.text('640x360'), findsNothing);
    });

    testWidgets('a_watch_that_is_dropped_clears_its_stats', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoRx(
          VideoRxSample(participantId: 'bbbb', width: 1920, height: 1080, framesPerSecond: 60, kbps: 5000)));
      callWith(tester); // the stream ends
      await tester.pumpAndSettle();
      callWith(tester, bobShare: const VideoFeed('TR_s2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.text('1920x1080'), findsNothing);
      expect(find.text('Waiting for video…'), findsOneWidget);
    });
  });
}
