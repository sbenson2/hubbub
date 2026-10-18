import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/hub_api.dart';
import 'package:hubbub/hub_controller.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/member_list.dart';
import 'package:hubbub/ui/theme.dart';
import 'package:hubbub/ui/user_panel.dart';

import 'support/fakes.dart';

void main() {
  late FakeHub hub;
  late FakeNode game;
  late FakeNode book;
  late FakeRoom room;
  late StreamController<AppNodeEvent> gameEvents;
  late StreamController<void> gameMembers;

  // Built inside each test body so the fakes' streams run in the test's fake-async zone.
  HubController arrange() {
    final me = member('aaaa', 'Shawn');
    gameEvents = StreamController<AppNodeEvent>.broadcast();
    gameMembers = StreamController<void>.broadcast();
    game = FakeNode(
      events: gameEvents,
      me: me,
      roster: [me, member('bbbb', 'Bob')],
      name: 'Game Night',
      textChannels: ['general'],
      voiceChannels: ['lobby'],
      membersChanged: gameMembers.stream,
    );
    final bookEvents = StreamController<AppNodeEvent>.broadcast();
    book = FakeNode(
      events: bookEvents,
      me: me,
      roster: [me],
      name: 'Book Club',
      textChannels: ['reading', 'chat'],
      voiceChannels: ['cafe'],
    );
    hub = FakeHub()
      ..add('c1', 'Game Night', game, isOwner: true)
      ..add('c2', 'Book Club', book);
    room = FakeRoom()
      ..onConnect = [RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true)];
    addTearDown(() async {
      game.dispose();
      book.dispose();
      await gameEvents.close();
      await gameMembers.close();
      await bookEvents.close();
    });
    final controller = HubController(hub)..refresh();
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpHub(WidgetTester tester, HubController controller) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: HomePage(
        hub: controller,
        room: room,
        loadConfig: () => throw StateError('a hub needs no config'),
      ),
    ));
    gameEvents.add(AppNodeEvent.hostChanged(host: game.me.id, term: BigInt.one, isMe: true));
    await tester.pumpAndSettle();
  }

  testWidgets('the_rail_shows_both_servers_and_switching_swaps_the_channel_list',
      (tester) async {
    final controller = arrange();
    await pumpHub(tester, controller);

    expect(find.byTooltip('Game Night'), findsOneWidget);
    expect(find.byTooltip('Book Club'), findsOneWidget);
    expect(find.text('lobby'), findsOneWidget);
    expect(find.text('cafe'), findsNothing);

    await tester.tap(find.byTooltip('Book Club'));
    await tester.pumpAndSettle();

    expect(controller.selectedCid, 'c2');
    expect(find.text('cafe'), findsOneWidget);
    expect(find.text('chat'), findsOneWidget);
    expect(find.text('lobby'), findsNothing);
    // The new server opened its first text channel.
    expect(find.text('reading'), findsWidgets);
  });

  testWidgets('a_voice_call_survives_switching_server', (tester) async {
    final controller = arrange();
    await pumpHub(tester, controller);

    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    expect(game.credentialRequests, ['lobby']);
    expect(room.calls, ['connect', 'mic:true', 'deafened:false']);
    room.calls.clear();

    await tester.tap(find.byTooltip('Book Club'));
    await tester.pumpAndSettle();

    // No disconnect; the call bar still names the call's own server.
    expect(room.calls, isEmpty);
    expect(find.byType(VoiceConnectedBar), findsOneWidget);
    expect(find.text('lobby / Game Night'), findsOneWidget);
    expect(book.credentialRequests, isEmpty);

    // Back in the first server the lobby shows the call.
    await tester.tap(find.byTooltip('Game Night'));
    await tester.pumpAndSettle();
    expect(room.calls, isEmpty);
    expect(find.text('lobby / Game Night'), findsOneWidget);
  });

  testWidgets('joining_voice_in_the_other_server_leaves_the_first_call', (tester) async {
    final controller = arrange();
    await pumpHub(tester, controller);
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    room.calls.clear();

    await tester.tap(find.byTooltip('Book Club'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cafe'));
    await tester.pumpAndSettle();

    expect(book.credentialRequests, ['cafe']);
    expect(room.calls.first, 'disconnect');
    expect(find.text('cafe / Book Club'), findsOneWidget);
  });

  testWidgets('members_changed_updates_the_member_list', (tester) async {
    final controller = arrange();
    await pumpHub(tester, controller);
    expect(find.descendant(of: find.byType(MemberList), matching: find.text('Carol')),
        findsNothing);

    game.roster.add(member('cccc', 'Carol'));
    gameMembers.add(null);
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(MemberList), matching: find.text('Carol')),
        findsOneWidget);
  });

  test('create_selects_the_new_server_and_join_selects_the_joined_one', () async {
    final controller = arrange();
    expect(controller.selectedCid, 'c1');

    final cid = await controller.create('Fresh');
    expect(controller.selectedCid, cid);
    expect(controller.communities.map((c) => c.name), ['Game Night', 'Book Club', 'Fresh']);

    final me = member('aaaa', 'Shawn');
    final other = FakeNode(
        events: StreamController<AppNodeEvent>.broadcast(),
        me: me,
        roster: [me],
        name: 'Elsewhere');
    addTearDown(other.dispose);
    hub.willJoin('hubbub://x', 'c9', 'Elsewhere', other);
    final events = await controller.join('hubbub://x').toList();
    expect(events.map((e) => e.runtimeType), [JoinTrying, JoinJoined]);
    expect(controller.selectedCid, 'c9');

    await controller.leave('c9');
    expect(controller.communities.length, 3);
    expect(controller.selectedCid, 'c1');
  });
}
