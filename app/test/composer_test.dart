import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/text_controller.dart';
import 'package:hubbub/ui/text_channel_view.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

void main() {
  late FakeTextService service;
  late TextController text;
  late StreamController<AppNodeEvent> events;

  setUp(() {
    service = FakeTextService();
    events = StreamController<AppNodeEvent>();
    text = TextController(service: service, events: events.stream, me: () => memberIdFor('aaaa'));
    text.open('general');
  });
  tearDown(() async {
    text.dispose();
    await events.close();
  });

  Future<void> pumpView(WidgetTester tester, {bool online = true}) async {
    await tester.pumpWidget(MaterialApp(
      theme: hubbubTheme(),
      home: Scaffold(
        body: TextChannelView(
          channel: 'general',
          text: text,
          nameOf: (id) => 'Shawn',
          online: online,
        ),
      ),
    ));
    await tester.pump();
  }

  Finder composer() => find.byKey(const ValueKey('composer'));

  testWidgets('enter_sends_through_the_text_controller_and_clears', (tester) async {
    await pumpView(tester);
    expect(find.text('Message #general'), findsOneWidget);

    await tester.enterText(composer(), 'hello there');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(service.sent, [('general', 'hello there')]);
    expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
    expect(find.text('hello there'), findsOneWidget);
  });

  testWidgets('shift_enter_adds_a_newline_and_does_not_send', (tester) async {
    await pumpView(tester);

    await tester.enterText(composer(), 'line one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(service.sent, isEmpty);
    expect(tester.widget<TextField>(composer()).controller!.text, 'line one\n');
  });

  testWidgets('enter_on_blank_input_sends_nothing', (tester) async {
    await pumpView(tester);

    await tester.enterText(composer(), '   ');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(service.sent, isEmpty);
  });

  testWidgets('input_is_capped_at_4000_characters', (tester) async {
    await pumpView(tester);

    await tester.enterText(composer(), 'x' * 4100);
    await tester.pump();

    expect(tester.widget<TextField>(composer()).controller!.text.length, 4000);
  });

  testWidgets('without_a_host_the_offline_banner_shows', (tester) async {
    await pumpView(tester, online: false);
    expect(
      find.text("Community offline — messages send when a member's PC is online."),
      findsOneWidget,
    );
  });
}
