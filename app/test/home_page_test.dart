import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/hub_controller.dart';
import 'package:hubbub/node_controller.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/channel_sidebar.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/member_list.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:hubbub/ui/user_panel.dart';

import 'support/fakes.dart';

void main() {
  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;

  // Built inside each test body, so the fakes' streams run in the test's fake-async zone.
  void arrange() {
    events = StreamController<AppNodeEvent>.broadcast();
    final me = member('aaaa', 'Shawn');
    node = FakeNode(events: events, me: me, roster: [me, member('bbbb', 'Bob')]);
    room = FakeRoom()
      ..onConnect = [RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true)];
    addTearDown(() async {
      node.dispose();
      await events.close();
    });
  }

  Future<void> pumpShell(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    arrange();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: HomePage(
        controller: node,
        room: room,
        loadConfig: () => throw StateError('a started node needs no config'),
      ),
    ));
    events.add(AppNodeEvent.hostChanged(host: node.me.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();
  }

  Future<void> joinLobby(WidgetTester tester) async {
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    expect(node.credentialRequests, ['lobby']);
    expect(room.calls, ['connect', 'mic:true', 'deafened:false']);
    room.calls.clear();
  }

  Future<void> joinLobbyAgain(WidgetTester tester) async {
    await tester.tap(find.text('lobby').first);
    await tester.pumpAndSettle();
    room.calls.clear();
  }

  testWidgets('clicking_a_voice_channel_joins_and_shows_voice_connected', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    expect(find.text('Voice Connected'), findsOneWidget);
    expect(find.text('lobby / Game Night'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byType(VoiceConnectedBar), matching: find.byTooltip('Disconnect')));
    await tester.pumpAndSettle();
    expect(room.calls, ['disconnect']);
    expect(find.text('Voice Connected'), findsNothing);
  });

  testWidgets('the_core_is_told_about_join_mute_deafen_and_leave', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);
    expect(node.voiceCalls, ['lobby false false']);

    await tester.tap(find.byTooltip('Mute').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Deafen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Undeafen'));
    await tester.pumpAndSettle();
    expect(node.voiceCalls, [
      'lobby false false',
      'lobby true false',
      'lobby true true',
      'lobby true false',
    ]);

    node.voiceCalls.clear();
    await tester.tap(find.descendant(
        of: find.byType(VoiceConnectedBar), matching: find.byTooltip('Disconnect')));
    await tester.pumpAndSettle();
    expect(node.voiceCalls, ['- false false']);
  });

  testWidgets('a_failed_join_clears_voice_and_a_dropped_call_does_too', (tester) async {
    await pumpShell(tester);
    room.micError = StateError('capture refused');
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    expect(node.voiceCalls, ['- false false']);

    room.micError = null;
    node.voiceCalls.clear();
    await joinLobbyAgain(tester);
    expect(node.voiceCalls, ['lobby false false']);
    room.emitSignal(RoomSignal.disconnected);
    await tester.pumpAndSettle();
    expect(node.voiceCalls, ['lobby false false', '- false false']);
  });


  testWidgets('a_failed_join_clears_voice_on_the_server_it_targeted_not_the_one_on_screen', (tester) async {
    arrange();
    final me = member('aaaa', 'Shawn');
    final other = FakeNode(events: StreamController<AppNodeEvent>.broadcast(), me: me, roster: [me], name: 'Other');
    addTearDown(other.dispose);
    final gate = Completer<void>();
    node.credentialsGate = gate;
    final api = FakeHub()..add('one', 'Game Night', node)..add('two', 'Other', other);
    final hub = HubController(api)..refresh();
    hub.select('one');
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: hubbubTheme(), home: HomePage(hub: hub, room: room, loadConfig: () => throw StateError('started'))));
    events.add(AppNodeEvent.hostChanged(host: me.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('lobby'));
    await tester.pump();
    hub.select('two');
    await tester.pump();
    gate.completeError(StateError('no credentials'));
    await tester.pumpAndSettle();
    expect(node.voiceCalls, ['- false false'], reason: 'the server the join targeted');
    expect(other.voiceCalls, isEmpty, reason: 'the server on screen was never joined');
  });

  testWidgets('a_failed_rejoin_clears_voice_but_a_good_rejoin_says_nothing', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);
    node.voiceCalls.clear();
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pumpAndSettle();
    expect(find.text('Voice Connected'), findsOneWidget);
    expect(node.voiceCalls, isEmpty, reason: 'same channel after a host change');

    room.connectError = StateError('no route');
    events.add(AppNodeEvent.hostChanged(host: 'cccc', term: BigInt.from(3), isMe: false));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Voice Connected'), findsNothing);
    expect(node.voiceCalls, ['- false false']);
  });

  testWidgets('the_sidebar_lists_who_is_in_a_channel_we_are_not_in', (tester) async {
    await pumpShell(tester);
    events.add(AppNodeEvent.voiceRoster(entries: [
      AppVoicePresence(member: memberIdFor('bbbb'), channel: 'lobby', muted: true, deafened: false),
    ]));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('voice:${memberIdFor('bbbb')}')), findsOneWidget);
    expect(find.text('Voice Connected'), findsNothing);

    events.add(const AppNodeEvent.voiceRoster(entries: []));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('voice:${memberIdFor('bbbb')}')), findsNothing);
  });

  testWidgets('a_host_change_during_a_call_reconnects_with_credentials_from_the_new_host', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    // We were host and in the call; another member takes over at a higher term.
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pumpAndSettle();

    expect(node.credentialRequests, ['lobby', 'lobby']);
    expect(room.calls, ['disconnect', 'connect', 'mic:true', 'deafened:false']);
    expect(find.text('Voice Connected'), findsOneWidget);
  });

  testWidgets('joining_connects_with_the_ice_server_from_the_credentials', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);
    expect(room.iceAtConnect, node.ice);
    expect(room.iceAtConnect, isNotNull);
  });

  testWidgets('a_host_change_rejoins_with_the_new_credentials_ice_server', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);
    const next = AppIceServer(url: 'turn:10.0.0.7:51000?transport=udp', username: 'hb2', credential: 'other');
    node.ice = next;

    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pumpAndSettle();

    expect(room.iceAtConnect, next, reason: 'the rejoin must use the ICE config of the new credentials');
  });

  testWidgets('a_node_without_a_usable_address_does_not_join_a_call_that_cannot_get_media', (tester) async {
    await pumpShell(tester);
    node.ice = null;
    final logs = <String?>[];
    final prev = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m);
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    debugPrint = prev;
    expect(room.calls, isNot(contains('connect')));
    expect(find.textContaining("Couldn't start voice: no network address for media"), findsOneWidget);
    expect(find.text('Voice Connected'), findsNothing);
    expect(logs.any((l) => l != null && l.startsWith('hubbub:') && l.contains('no network address')), isTrue);
  });

  testWidgets('a_host_change_during_an_in_flight_rejoin_is_not_lost', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.connectGate = Completer<void>();
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pump();
    expect(node.credentialRequests, ['lobby', 'lobby']);
    // Another change lands while the rejoin to bbbb is still connecting.
    events.add(AppNodeEvent.hostChanged(host: 'cccc', term: BigInt.from(3), isMe: false));
    await tester.pump();
    final gate = room.connectGate!;
    room.connectGate = null;
    gate.complete();
    await tester.pumpAndSettle();

    expect(node.credentialRequests, ['lobby', 'lobby', 'lobby']);
    expect(find.text('Voice Connected'), findsOneWidget);
  });

  testWidgets('a_failed_rejoin_disconnects_the_room_and_ends_the_call', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.connectError = StateError('no route');
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pump(const Duration(seconds: 3)); // past the one retry
    await tester.pumpAndSettle();

    expect(room.calls, contains('disconnect'));
    expect(find.text('Voice Connected'), findsNothing);
  });

  testWidgets('a_join_that_fails_after_connect_disconnects_the_room', (tester) async {
    await pumpShell(tester);
    room.micError = StateError('capture refused');

    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();

    expect(room.calls, ['connect', 'mic:true', 'disconnect']);
    expect(room.connected, isFalse);
    expect(find.text('Voice Connected'), findsNothing);
  });

  testWidgets('a_rejoin_drops_the_old_room_before_applying_devices_and_retries_once', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.connectFailures = 1;
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(room.calls.first, 'disconnect', reason: 'before any device is applied to the old room');
    expect(room.calls.where((c) => c == 'connect').length, 2, reason: 'one retry');
    expect(find.text('Voice Connected'), findsOneWidget);
  });

  testWidgets('a_disconnect_with_no_host_change_says_so_and_ends_the_call', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.emitSignal(RoomSignal.disconnected);
    await tester.pumpAndSettle();

    expect(find.textContaining('Click it to rejoin'), findsOneWidget);
    expect(find.text('Voice Connected'), findsNothing);
  });

  testWidgets('a_failed_unmute_in_a_call_is_reported_and_the_button_reverts', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.micError = StateError('capture refused');
    await tester.tap(find.byTooltip('Mute').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('capture refused'), findsOneWidget);
    expect(find.byTooltip('Mute'), findsWidgets, reason: 'the mic is still on');
  });

  testWidgets('a_rejoin_retry_follows_a_host_change_from_its_wait', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.connectFailures = 1;
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pump();
    // The connect to bbbb failed; the host moves on before the retry.
    events.add(AppNodeEvent.hostChanged(host: 'cccc', term: BigInt.from(3), isMe: false));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(node.credentialRequests, ['lobby', 'lobby', 'lobby'], reason: 'fresh credentials for cccc');
    expect(room.calls.where((c) => c == 'connect').length, 2,
        reason: 'the failed bbbb connect, then cccc; no retry with the bbbb credentials');
    expect(find.text('Voice Connected'), findsOneWidget);
  });

  testWidgets('a_deafen_whose_mute_fails_still_shows_deafened', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    room.micError = StateError('capture refused');
    await tester.tap(find.byTooltip('Deafen'));
    await tester.pumpAndSettle();

    expect(room.calls.where((c) => c.startsWith('deafened')), ['deafened:true']);
    expect(find.byTooltip('Undeafen'), findsWidgets, reason: 'the room did deafen');
  });

  testWidgets('deafen_mutes_the_mic_and_undeafen_restores_both', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    await tester.tap(find.byTooltip('Deafen'));
    await tester.pumpAndSettle();
    expect(room.calls, ['deafened:true', 'mic:false']);
    expect(find.byTooltip('Unmute'), findsWidgets);

    room.calls.clear();
    await tester.tap(find.byTooltip('Undeafen'));
    await tester.pumpAndSettle();
    expect(room.calls, ['deafened:false', 'mic:true']);
    expect(find.byTooltip('Mute'), findsWidgets);
  });

  testWidgets('undeafen_keeps_a_mute_chosen_before_deafening', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    await tester.tap(find.byTooltip('Mute').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Deafen'));
    await tester.pumpAndSettle();
    room.calls.clear();

    await tester.tap(find.byTooltip('Undeafen'));
    await tester.pumpAndSettle();
    expect(room.calls, ['deafened:false', 'mic:false']);
    expect(find.byTooltip('Unmute'), findsWidgets);
  });

  testWidgets('the_member_list_toggles_from_the_header', (tester) async {
    await pumpShell(tester);
    expect(find.byType(MemberList), findsOneWidget);

    await tester.tap(find.byTooltip('Hide Member List'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberList), findsNothing);

    await tester.tap(find.byTooltip('Show Member List'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberList), findsOneWidget);
  });

  for (final width in [600.0, 360.0]) {
    testWidgets('a_${width.toInt()}px_window_puts_channels_in_a_drawer_without_overflow',
        (tester) async {
      await pumpShell(tester, size: Size(width, 640));
      expect(find.byType(MemberList), findsNothing);
      expect(find.byType(ChannelSidebar), findsNothing);

      await tester.tap(find.byTooltip('Channels'));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelSidebar), findsOneWidget);

      await tester.tap(find.text('lobby'));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelSidebar), findsNothing, reason: 'choosing a channel closes the drawer');
      expect(room.calls, contains('connect'));
    });
  }

  testWidgets('without_a_community_file_no_import_path_shows', (tester) async {
    final idle = NodeController();
    addTearDown(idle.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: HomePage(
        controller: idle,
        room: FakeRoom(),
        loadConfig: () async => const AppNodeConfig(
          dataDir: '/nonexistent',
          communityFile: '/nonexistent/community.json',
          canHost: false,
        ),
      ),
    ));
    expect(find.text('Connecting to your community…'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('No community yet'), findsOneWidget);
    expect(find.text('Import community file'), findsNothing);
    expect(find.byTooltip('Add a Server'), findsOneWidget);
  }, skip: kIsWeb); // The check reads the file system.

  testWidgets('room_signals_keep_their_hubbub_log_lines', (tester) async {
    final logged = <String>[];
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logged.add(message ?? '');
    try {
      await pumpShell(tester);
      room.emitSignal(RoomSignal.firstRemoteAudio);
      room.emitSignal(RoomSignal.disconnected);
      await tester.pump();
    } finally {
      debugPrint = print;
    }

    expect(logged, containsAllInOrder(['hubbub: firstRemoteAudio', 'hubbub: disconnected']));
  });
}

