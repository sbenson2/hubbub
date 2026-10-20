import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/share_sources.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

AppMediaSnapshot snapshot({required int sent, required int lost, required int rtt, String path = 'direct'}) =>
    AppMediaSnapshot(
      links: [
        AppMediaLink(
            role: 'uplink', path: path, rttMs: rtt, cwnd: 60000, sentPackets: sent, lostPackets: lost,
            congestionEvents: 0, mtu: 1452, maxDatagram: 1410, sendBufferSpace: 131072, frameTxDatagrams: sent),
      ],
      wireTxPkts: sent, wireRxPkts: sent, viaStream: 0, dropped: 0, trySendFailed: 0, dgramEnqueued: sent);

void main() {
  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;
  late AppMember me;
  late FakeShareSources shares;
  late FakePortalSource portal;
  late List<bool> fullscreen;

  Future<void> pumpShell(WidgetTester tester,
      {DevicePrefs prefs = const DevicePrefs(), bool screenShare = true,
      bool portalShare = false}) async {
    shares = FakeShareSources();
    portal = FakePortalSource();
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
        shareStillExists: shares.exists,
        screenShareAvailable: screenShare,
        portalShare: portalShare,
        portalSource: portal.call,
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
      expect(room.calls, ['disconnect', 'connect', 'mic:true', 'deafened:false', 'camera:true']);
      expect(find.byTooltip('Turn Off Camera'), findsOneWidget);
    });
  });

  group('wayland screen share', () {
    const cancelled = 'Screen sharing was cancelled';
    const noScreen = 'No screen was chosen';

    Future<void> pressShare(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the_share_button_waits_for_the_system_dialog_and_opens_no_picker', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      portal.gate = Completer<String?>();
      await pressShare(tester);
      expect(find.text('Choose a screen in the system dialog'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Go Live'), findsNothing);
      expect(find.text('Screens'), findsNothing);
      expect(shares.loads, 0, reason: 'the picker list (screens and windows) is never asked for');
      expect(portal.calls, 1);
      expect(room.calls, isEmpty);
    });

    testWidgets('the_pick_starts_the_share_with_the_id_the_loader_returned', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      portal.gate = Completer<String?>();
      await pressShare(tester);
      portal.gate!.complete('portal-7');
      await tester.pumpAndSettle();
      expect(find.text('Choose a screen in the system dialog'), findsNothing);
      expect(room.calls, ['screen:true:portal-7']);
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop Streaming'));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:true:portal-7', 'screen:false']);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('cancel_in_hubbub_stops_the_wait_and_shares_nothing', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      portal.gate = Completer<String?>();
      await pressShare(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(portal.lastCancel!.cancelled, isTrue);
      expect(room.calls, isEmpty);
      expect(find.text('Choose a screen in the system dialog'), findsNothing);
      expect(find.text(cancelled), findsOneWidget);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('no_pick_in_time_shares_nothing_and_says_no_screen_was_chosen', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      portal.error = TimeoutException('nobody chose');
      await pressShare(tester);
      await tester.pumpAndSettle();
      expect(room.calls, isEmpty);
      expect(find.text(noScreen), findsOneWidget);
      expect(find.text(cancelled), findsNothing);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('a_portal_that_fails_says_why_and_shares_nothing', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      portal.error = StateError('no portal');
      await pressShare(tester);
      await tester.pumpAndSettle();
      expect(room.calls, isEmpty);
      expect(find.textContaining('Could not start the stream'), findsOneWidget);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
    });

    testWidgets('a_portal_share_is_never_checked_for_a_vanished_source', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(shares.checks, 0);
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);
    });

    testWidgets('a_host_change_keeps_the_portal_stream_and_never_asks_for_the_dead_id', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:true:portal-1']);
      room.calls.clear();

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:hold', 'disconnect', 'connect', 'mic:true', 'deafened:false', 'screen:resume']);
      expect(room.calls.where((c) => c.startsWith('screen:true')), isEmpty,
          reason: 'the placeholder id is dead: asking for it opens a surprise system prompt');
      expect(portal.calls, 1, reason: 'no second system prompt');
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop Streaming'));
      await tester.pumpAndSettle();
      expect(room.calls.last, 'screen:false');
    });

    testWidgets('a_portal_share_that_cannot_resume_says_to_choose_again', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      room.calls.clear();
      room.resumeError = StateError('publish timed out');

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c.startsWith('screen:true')), isEmpty);
      expect(find.text('Your screen share stopped when the call moved. Choose a screen to share again.'),
          findsOneWidget);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
      expect(portal.calls, 1, reason: 'the user chooses again by pressing Share, not by a surprise prompt');
    });

    testWidgets('a_rejoin_that_fails_stops_the_kept_portal_stream', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      room.calls.clear();
      room.connectError = StateError('host gone');

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(room.calls, contains('screen:hold'));
      expect(room.calls, contains('screen:release'), reason: 'a kept capture must not run on with no call');
    });

    testWidgets('a_call_that_ends_while_the_stream_is_being_kept_does_not_leave_it_running', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      room.calls.clear();
      room.holdGate = Completer<void>();

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pump();
      await tester.tap(find.byTooltip('Disconnect').first);
      await tester.pump();
      room.holdGate!.complete();
      await tester.pumpAndSettle();
      expect(room.calls.where((c) => c == 'screen:release'), hasLength(1),
          reason: 'the call ended before the hold finished: nobody is left to resume the capture');
      expect(room.calls, isNot(contains('screen:resume')));
    });

    testWidgets('a_rejoin_that_gives_way_to_a_newer_host_keeps_the_stream_for_the_next_rejoin', (tester) async {
      await pumpShell(tester, portalShare: true);
      await joinLobby(tester);
      await pressShare(tester);
      await tester.pumpAndSettle();
      room.calls.clear();
      room.connectFailures = 1;

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pump(const Duration(seconds: 1));
      // A third host appears while the first retry waits: the retry gives way to it.
      events.add(AppNodeEvent.hostChanged(host: 'cccc', term: BigInt.from(3), isMe: false));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(room.calls, isNot(contains('screen:release')), reason: 'the next rejoin resumes it');
      expect(room.calls.where((c) => c == 'screen:resume'), hasLength(1));
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);
    });

    testWidgets('a_picker_share_is_not_held_across_a_host_change', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Screen 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      room.calls.clear();

      events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
      await tester.pumpAndSettle();
      expect(room.calls, ['disconnect', 'connect', 'mic:true', 'deafened:false', 'screen:true:screen:0:0']);
    });

    testWidgets('the_picker_flow_is_unchanged_when_not_in_portal_mode', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      expect(find.text('Screens'), findsOneWidget);
      expect(portal.calls, 0);
      await tester.tap(find.text('Screen 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:true:screen:0:0']);
      await tester.pump(const Duration(seconds: 3));
      expect(shares.checks, greaterThan(0), reason: 'a picker share is still watched');
      expect(portal.calls, 0);
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
      expect(room.calls, ['disconnect', 'connect', 'mic:true', 'deafened:false', 'screen:true:screen:0:0']);
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
        participantId: 'bbbb',
        width: 1920,
        height: 1080,
        framesPerSecond: 59.6,
        kbps: 5400.4,
        framesDropped: 3,
        decoder: 'OpenH264');

    test('video_rx_line_has_the_resolution_fps_and_kbps', () {
      expect(formatVideoRx(sample),
          'video_rx from=bbbb 1920x1080 fps=59.6 kbps=5400 dropped=3 dec=OpenH264 src=screen');
      expect(formatVideoRx(const VideoRxSample()),
          'video_rx from=? 0x0 fps=0.0 kbps=0 dropped=0 dec=- src=screen');
    });

    test('video_tx_line_has_the_capture_rate_and_every_layer', () {
      const tx = VideoTxSample(
        source: 'screen',
        captureWidth: 1920,
        captureHeight: 1080,
        captureFps: 59.8,
        rttMs: 3.4,
        layers: [
          VideoTxLayer(
              rid: 'f', width: 1920, height: 1080, framesPerSecond: 29.6, kbps: 5400.2, limitation: 'cpu', encoder: 'OpenH264'),
          VideoTxLayer(rid: 'q', width: 640, height: 360, framesPerSecond: 15),
        ],
      );
      expect(formatVideoTx(tx),
          'video_tx src=screen capture=1920x1080@59.8 rtt=3ms f=1920x1080@29.6/5400kbps/cpu/OpenH264 q=640x360@15.0/0kbps/-/-');
      expect(formatVideoTx(const VideoTxSample()), 'video_tx src=screen capture=0x0@0.0 rtt=-');
    });

    test('tx_reports_reduce_to_capture_layers_rtt_and_bitrate', () {
      rtc.StatsReport out(num bytes, double ts) => rtc.StatsReport('o1', 'outbound-rtp', ts, {
            'kind': 'video',
            'rid': 'f',
            'frameWidth': 1920,
            'frameHeight': 1080,
            'framesPerSecond': 59.0,
            'bytesSent': bytes,
            'qualityLimitationReason': 'none',
            'encoderImplementation': 'OpenH264',
          });
      final rest = [
        rtc.StatsReport('m', 'media-source', 0, {'kind': 'video', 'width': 1920, 'height': 1080, 'framesPerSecond': 30.0}),
        rtc.StatsReport('t', 'transport', 0, {'selectedCandidatePairId': 'c'}),
        rtc.StatsReport('c', 'candidate-pair', 0, {'nominated': true, 'currentRoundTripTime': 0.012}),
      ];
      final prev = <String, (num, num)>{};
      final first = videoTxFromReports('screen', [out(0, 7), ...rest], prev, nowMs: 1000);
      expect(first.layers.single.kbps, isNull);
      final second = videoTxFromReports('screen', [out(125000, 7), ...rest], prev, nowMs: 2000);
      expect(second.captureFps, 30.0);
      expect(second.captureWidth, 1920);
      expect(second.rttMs, closeTo(12, 0.001));
      expect(second.layers.single.kbps, closeTo(1000, 0.001));
      expect(second.layers.single.limitation, 'none');
      expect(second.layers.single.encoder, 'OpenH264');
    });

    test('a_camera_sample_is_filed_apart_from_the_screen_share', () {
      expect(const VideoRxSample(participantId: 'bbbb').key, 'bbbb');
      expect(const VideoRxSample(participantId: 'bbbb', source: 'camera').key, 'bbbb/camera');
    });

    testWidgets('the_overlay_adds_your_own_tx_line_while_you_share', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      const tx = VideoTxSample(source: 'screen', captureFps: 30, layers: [
        VideoTxLayer(rid: 'f', width: 1920, height: 1080, framesPerSecond: 29.6, limitation: 'cpu'),
        VideoTxLayer(rid: 'q', width: 640, height: 360, framesPerSecond: 15, limitation: 'none'),
      ]);
      room.emitSignal(const RoomVideoTx(tx));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sending'), findsNothing, reason: 'not sharing yet');

      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Screen 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoTx(tx));
      await tester.pumpAndSettle();
      expect(find.text('Sending screen 1920x1080 30 fps'), findsOneWidget);
      expect(find.text('limited by cpu'), findsOneWidget);
    });

    testWidgets('the_overlay_shows_the_media_connection_line_from_each_stats_tick', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connection:'), findsNothing, reason: 'no sample yet');

      node.link = snapshot(sent: 1000, lost: 0, rtt: 42);
      room.emitSignal(const RoomStats(StatsSample()));
      await tester.pumpAndSettle();
      expect(find.text('Connection: direct · 42 ms · 0.0% loss'), findsOneWidget);

      node.link = snapshot(sent: 2000, lost: 1, rtt: 44);
      room.emitSignal(const RoomStats(StatsSample()));
      await tester.pumpAndSettle();
      expect(find.text('Connection: direct · 44 ms · 0.1% loss'), findsOneWidget);

      node.link = snapshot(sent: 3000, lost: 1, rtt: 90, path: 'relay');
      room.emitSignal(const RoomStats(StatsSample()));
      await tester.pumpAndSettle();
      expect(find.text('Connection: relay · 90 ms · 0.0% loss'), findsOneWidget);
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

    testWidgets('a_focused_camera_has_stats_too', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobCamera: const VideoFeed('TR_cam'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tile:bbbb')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for video…'), findsOneWidget);
      room.emitSignal(const RoomVideoRx(VideoRxSample(
          participantId: 'bbbb', source: 'camera', width: 1280, height: 720, framesPerSecond: 30, kbps: 2000)));
      room.emitSignal(const RoomVideoRx(
          VideoRxSample(participantId: 'bbbb', width: 1920, height: 1080, framesPerSecond: 60, kbps: 5000)));
      await tester.pumpAndSettle();
      expect(find.text('1280x720'), findsOneWidget);
      expect(find.text('1920x1080'), findsNothing, reason: 'the share of the same person is not the camera');
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
      expect(lines, contains('hubbub: video_rx from=bbbb 1920x1080 fps=59.6 kbps=5400 dropped=3 dec=OpenH264 src=screen'));
    });

    testWidgets('every_outbound_sample_is_logged_as_video_tx', (tester) async {
      final lines = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
      try {
        await pumpShell(tester);
        await joinLobby(tester);
        room.emitSignal(const RoomVideoTx(VideoTxSample(source: 'camera', captureFps: 30)));
        await tester.pump();
      } finally {
        debugPrint = old;
      }
      expect(lines, contains('hubbub: video_tx src=camera capture=0x0@30.0 rtt=-'));
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

    testWidgets('a_share_ends_when_its_window_goes_away', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Applications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Doom Eternal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go Live'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop Streaming'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      expect(find.byTooltip('Stop Streaming'), findsOneWidget, reason: 'the window is still there');

      shares.sources = [for (final s in shares.sources) if (s.id != 'window:42:0') s];
      room.calls.clear();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(room.calls, ['screen:false']);
      expect(find.byTooltip('Share Your Screen'), findsOneWidget);
      expect(find.textContaining('shared window closed'), findsOneWidget);
    });

    testWidgets('where_screen_capture_is_unavailable_the_button_says_so_and_opens_no_picker', (tester) async {
      await pumpShell(tester, screenShare: false);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Share Your Screen'));
      await tester.pumpAndSettle();
      expect(find.text("Screen sharing isn't supported on this desktop yet"), findsOneWidget);
      expect(find.text('Go Live'), findsNothing);
      expect(shares.loads, 0);
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
  group('fix round 2', () {
    const stream = VideoFeed('TR_s');

    testWidgets('a_watched_share_is_high_only_while_focused_and_low_when_not', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobShare: stream, bobCamera: const VideoFeed('TR_cam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watch Stream'));
      await tester.pumpAndSettle();
      List<String> q() => room.calls.where((c) => c.startsWith('quality:')).toList();
      // Watching focuses the share: it is asked for at its best layer before it is subscribed.
      expect(q(), ['quality:bbbb:TR_s:high']);
      expect(room.calls.indexOf('quality:bbbb:TR_s:high'), lessThan(room.calls.indexOf('video:bbbb:TR_s:true')));

      // Focusing the camera hands the best layer over: the share (now in the strip) goes low.
      await tester.tap(find.byKey(const ValueKey('tile:bbbb')));
      await tester.pumpAndSettle();
      expect(q(), containsAll(['quality:bbbb:TR_s:low', 'quality:bbbb:TR_cam:high']));
    });

    testWidgets('a_hidden_window_stops_all_remote_video_and_showing_it_resumes', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobCamera: const VideoFeed('TR_cam'));
      await tester.pumpAndSettle();
      room.shownCalls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(room.shownCalls, ['shown:false:']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(room.shownCalls, ['shown:false:', 'shown:true:']);
    });

    testWidgets('strip_tiles_scrolled_out_of_view_stop_receiving', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      // Ten cameras: the focused one is large, nine tiles in a strip far wider than the window.
      room.emitParticipants([
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true),
        for (var i = 0; i < 10; i++)
          RoomParticipant(
              id: 'p$i', name: 'P$i', speaking: false, isLocal: false, camera: VideoFeed('TR_$i')),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tile:p0')));
      await tester.pumpAndSettle();
      final hidden = room.shownCalls.last;
      expect(hidden, startsWith('shown:true:TR_'));
      expect(hidden, contains('TR_9'));
      expect(hidden, isNot(contains('TR_1,')));
      expect(hidden, isNot(contains('TR_0')), reason: 'the focused tile is not in the strip');

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(room.shownCalls.last, 'shown:true:');
    });

    testWidgets('a_camera_that_stops_drops_its_stats_and_a_stopped_share_its_tx', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      callWith(tester, bobCamera: const VideoFeed('TR_cam'));
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoRx(VideoRxSample(
          participantId: 'bbbb', source: 'camera', width: 1280, height: 720, framesPerSecond: 30, kbps: 2000)));
      await tester.pumpAndSettle();
      callWith(tester); // Bob's camera goes off
      await tester.pumpAndSettle();
      callWith(tester, bobCamera: const VideoFeed('TR_cam2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tile:bbbb')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.text('1280x720'), findsNothing);
      expect(find.text('Waiting for video…'), findsOneWidget);
    });

    testWidgets('your_own_send_stats_show_on_your_own_focused_tile_and_never_as_0x0', (tester) async {
      await pumpShell(tester);
      await joinLobby(tester);
      await tester.tap(find.byTooltip('Turn On Camera'));
      await tester.pumpAndSettle();
      room.emitParticipants([
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true, camera: const VideoFeed('TR_me')),
        RoomParticipant(id: 'bbbb', name: 'Bob', speaking: false, isLocal: false),
      ]);
      await tester.pumpAndSettle();
      room.emitSignal(const RoomVideoTx(VideoTxSample(source: 'camera')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('tile:${me.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stream Stats'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sending'), findsNothing, reason: 'no picture yet, so no 0x0 line');
      room.emitSignal(const RoomVideoTx(VideoTxSample(source: 'camera', layers: [
        VideoTxLayer(rid: 'f', width: 1280, height: 720, framesPerSecond: 30, limitation: 'cpu'),
        VideoTxLayer(rid: 'q', width: 640, height: 360, framesPerSecond: 0, limitation: 'bandwidth'),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('Sending camera 1280x720 30 fps'), findsOneWidget);
      expect(find.text('limited by cpu'), findsOneWidget);
      expect(find.text('limited by bandwidth'), findsNothing, reason: 'that layer is paused');
    });
  });
}
