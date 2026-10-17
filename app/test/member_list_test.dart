import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/node_controller.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/member_list.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('online_offline_split_follows_peer_events', (tester) async {
    final me = member('aaaa', 'Shawn');
    final bob = member('bbbb', 'Bob');
    final cat = member('cccc', 'Cat');
    final dan = member('dddd', 'Dan');
    final events = StreamController<AppNodeEvent>();
    final node = NodeController(eventsOverride: events.stream);
    addTearDown(node.dispose);
    addTearDown(events.close);

    events
      ..add(AppNodeEvent.peerUp(member: bob.id, direct: true))
      ..add(AppNodeEvent.peerUp(member: cat.id, direct: false))
      ..add(AppNodeEvent.peerDown(member: cat.id))
      ..add(AppNodeEvent.hostChanged(host: bob.id, term: BigInt.one, isMe: false));
    await tester.pump();
    expect(node.online, {bob.id});

    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: Scaffold(
        body: MemberList(
          members: [me, bob, cat, dan],
          me: me.id,
          online: node.online,
          host: node.host,
        ),
      ),
    ));

    expect(find.text('ONLINE — 2'), findsOneWidget);
    expect(find.text('OFFLINE — 2'), findsOneWidget);

    Opacity rowOpacity(String name) => tester.widget<Opacity>(find
        .ancestor(of: find.text(name), matching: find.byType(Opacity))
        .first);
    expect(rowOpacity('Cat').opacity, 0.3);
    expect(rowOpacity('Dan').opacity, 0.3);
    expect(find.ancestor(of: find.text('Shawn'), matching: find.byType(Opacity)), findsNothing);

    final bobRow = find.byKey(ValueKey('member:${bob.id}'));
    expect(find.descendant(of: bobRow, matching: find.byTooltip('Hosting')), findsOneWidget);
  });
}
