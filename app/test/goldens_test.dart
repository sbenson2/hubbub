import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/ui/home_page.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';
import 'support/fonts.dart';

/// Screenshots of the shell at 1280×800 with fake data. Web test runs cannot load the
/// bundled fonts, so these run on the native tester only. The goldens are rendered on
/// Windows, the dev machine; other hosts antialias text differently (about 3% of pixels):
///   flutter test --update-goldens test/goldens_test.dart
void main() {
  setUpAll(() async {
    if (!kIsWeb) await loadAppFonts();
  });

  final now = DateTime(2026, 10, 17, 15, 30);
  final me = member('ad27', 'Shawn');
  final maya = member('b371', 'Maya');
  final theo = member('c149', 'Theo');
  final priya = member('deeb', 'Priya');

  late StreamController<AppNodeEvent> events;
  late FakeNode node;
  late FakeRoom room;

  // Built inside each test body, so the fakes' streams run in the test's fake-async zone.
  void arrange() {
    events = StreamController<AppNodeEvent>.broadcast();
    final text = FakeTextService();
    final yesterday = DateTime(2026, 10, 16);
    final today = DateTime(2026, 10, 17);
    DateTime at(DateTime day, int h, int m) => DateTime(day.year, day.month, day.day, h, m);
    var id = 0;
    AppTextMessage say(AppMember who, DateTime t, String body) =>
        textMessage(from: who.id, clientId: ++id, at: t, body: body, seq: id);
    text.history['general'] = [
      say(theo, at(yesterday, 21, 12), 'anyone up for a round tomorrow night?'),
      say(theo, at(yesterday, 21, 13), 'thinking 8ish, after dinner'),
      say(maya, at(yesterday, 21, 20), "I'm in. Bringing the new map pack"),
      say(me, at(today, 14, 58), 'Hubbub build is up. Grab the community file from the shared drive'),
      say(me, at(today, 15, 1), 'voice should hand over on its own if my PC goes to sleep'),
      say(maya, at(today, 15, 5), 'nice, joining from the laptop'),
      say(maya, at(today, 15, 14), 'mic check works on my end'),
      say(theo, at(today, 15, 16), 'see you in the lobby at 8'),
    ];
    node = FakeNode(
      events: events,
      me: me,
      roster: [me, maya, theo, priya],
      textChannels: const ['general', 'games', 'clips'],
      voiceChannels: const ['lobby', 'squad'],
      name: 'Game Night',
      text: text,
    );
    room = FakeRoom()
      ..onConnect = [
        RoomParticipant(id: me.id, name: 'Shawn', speaking: false, isLocal: true),
        RoomParticipant(id: maya.id, name: 'Maya', speaking: true, isLocal: false),
        RoomParticipant(id: theo.id, name: 'Theo', speaking: false, isLocal: false, muted: true),
      ];
    addTearDown(() async {
      node.dispose();
      await events.close();
    });
  }

  Future<void> pumpShell(WidgetTester tester, {required bool online}) async {
    arrange();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: hubbubTheme(),
      home: HomePage(
        controller: node,
        room: room,
        loadConfig: () => throw StateError('a started node needs no config'),
        clock: () => now,
      ),
    ));
    if (online) {
      events
        ..add(AppNodeEvent.peerUp(member: maya.id, direct: true))
        ..add(AppNodeEvent.peerUp(member: theo.id, direct: true))
        ..add(AppNodeEvent.hostChanged(host: maya.id, term: BigInt.one, isMe: false))
        // Arrives while #games is not on screen: it shows as unread.
        ..add(AppNodeEvent.text(
            message: textMessage(from: theo.id, clientId: 99, channel: 'games', at: now)));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('golden_text_channel', (tester) async {
    await pumpShell(tester, online: true);
    await expectLater(find.byType(HomePage), matchesGoldenFile('goldens/text_channel.png'));
  }, skip: kIsWeb);

  testWidgets('golden_voice_channel', (tester) async {
    await pumpShell(tester, online: true);
    await tester.tap(find.text('lobby'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(HomePage), matchesGoldenFile('goldens/voice_channel.png'));
  }, skip: kIsWeb);

  testWidgets('golden_offline_banner', (tester) async {
    await pumpShell(tester, online: false);
    // Sent while no host is up: it stays dimmed until delivered.
    await tester.enterText(find.byKey(const ValueKey('composer')), 'anyone around? my PC is asleep');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await expectLater(find.byType(HomePage), matchesGoldenFile('goldens/offline_banner.png'));
  }, skip: kIsWeb);
}
