import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('a_host_change_during_a_call_reconnects_with_credentials_from_the_new_host', (tester) async {
    await pumpShell(tester);
    await joinLobby(tester);

    // We were host and in the call; another member takes over at a higher term.
    events.add(AppNodeEvent.hostChanged(host: 'bbbb', term: BigInt.from(2), isMe: false));
    await tester.pumpAndSettle();

    expect(node.credentialRequests, ['lobby', 'lobby']);
    expect(room.calls, ['connect', 'mic:true', 'deafened:false']);
    expect(find.text('Voice Connected'), findsOneWidget);
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

