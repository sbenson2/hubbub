import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/ui/avatar.dart';
import 'package:hubbub/ui/channel_sidebar.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

void main() {
  final alice = memberIdFor('aaaa');
  final bob = memberIdFor('bbbb');
  final cat = memberIdFor('cccc');

  Widget sidebar({
    ChannelRef? selected,
    Set<String> unread = const {},
    ValueChanged<ChannelRef>? onSelect,
  }) =>
      MaterialApp(
        theme: hubbubTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: ChannelSidebar(
              communityName: 'Game Night',
              textChannels: const ['general', 'games'],
              voiceChannels: const ['lobby', 'afk'],
              selected: selected,
              isUnread: unread.contains,
              connectedVoice: 'lobby',
              voiceMembers: [
                VoiceMember(id: alice, name: 'Alice', speaking: true, hosting: true),
                VoiceMember(id: bob, name: 'Bob', muted: true),
                VoiceMember(id: cat, name: 'Cat', muted: true, deafened: true),
              ],
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      );

  Finder row(String id) => find.byKey(ValueKey('voice:$id'));

  testWidgets('voice_participants_show_speaking_muted_and_host', (tester) async {
    await tester.pumpWidget(sidebar());

    final aliceAvatar = tester.widget<Avatar>(
        find.descendant(of: row(alice), matching: find.byType(Avatar)));
    expect(aliceAvatar.speaking, isTrue);
    final bobAvatar =
        tester.widget<Avatar>(find.descendant(of: row(bob), matching: find.byType(Avatar)));
    expect(bobAvatar.speaking, isFalse);

    expect(find.descendant(of: row(alice), matching: find.byTooltip('Hosting')), findsOneWidget);
    expect(find.byTooltip('Hosting'), findsOneWidget);

    expect(find.descendant(of: row(alice), matching: find.byTooltip('Muted')), findsNothing);
    expect(find.descendant(of: row(bob), matching: find.byTooltip('Muted')), findsOneWidget);
    expect(find.descendant(of: row(bob), matching: find.byTooltip('Deafened')), findsNothing);
    expect(find.descendant(of: row(cat), matching: find.byTooltip('Deafened')), findsOneWidget);
  });

  testWidgets('channels_select_and_unread_text_is_bold_white', (tester) async {
    final picked = <ChannelRef>[];
    await tester.pumpWidget(sidebar(
      selected: const ChannelRef.text('general'),
      unread: {'games'},
      onSelect: picked.add,
    ));

    final games = tester.widget<Text>(find.text('games'));
    expect(games.style?.color, HubColors.white);
    expect(games.style?.fontWeight, FontWeight.w600);

    await tester.tap(find.text('afk'));
    await tester.tap(find.text('games'));
    expect(picked, const [ChannelRef.voice('afk'), ChannelRef.text('games')]);
  });

  testWidgets('a_collapsed_category_keeps_only_the_selected_channel', (tester) async {
    await tester.pumpWidget(sidebar(selected: const ChannelRef.text('general')));

    await tester.tap(find.text('TEXT CHANNELS'));
    await tester.pump();

    expect(find.text('general'), findsOneWidget);
    expect(find.text('games'), findsNothing);
  });
}
