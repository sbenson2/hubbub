import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/node_controller.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';

void main() {
  test('host_changed_event_updates_state', () async {
    final events = StreamController<AppNodeEvent>();
    final controller = NodeController(eventsOverride: events.stream);
    addTearDown(controller.dispose);
    addTearDown(events.close);

    events.add(AppNodeEvent.hostChanged(
        host: 'ab..', term: BigInt.two, isMe: false));
    await Future<void>.delayed(Duration.zero);

    expect(controller.host, 'ab..');
    expect(controller.term, 2);
    expect(controller.isHost, false);
  });

  test('voice_roster_event_replaces_who_is_in_each_channel_and_logs', () async {
    final logged = <String>[];
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logged.add(message ?? '');
    addTearDown(() => debugPrint = print);
    final events = StreamController<AppNodeEvent>();
    final controller = NodeController(eventsOverride: events.stream);
    addTearDown(controller.dispose);
    addTearDown(events.close);
    var notified = 0;
    controller.addListener(() => notified++);

    AppVoicePresence at(String tag, String channel, {bool muted = false}) => AppVoicePresence(
        member: '${tag.toLowerCase()}${'0' * 60}', channel: channel, muted: muted, deafened: false);
    events.add(AppNodeEvent.voiceRoster(entries: [at('aaaa', 'lobby'), at('bbbb', 'afk', muted: true)]));
    await Future<void>.delayed(Duration.zero);
    expect(controller.voiceIn('lobby').map((e) => e.member), ['aaaa${'0' * 60}']);
    expect(controller.voiceIn('afk').single.muted, isTrue);
    expect(controller.voiceIn('nowhere'), isEmpty);
    expect(notified, 1);
    expect(logged, contains('hubbub: VoiceRoster 2 in voice'));

    events.add(const AppNodeEvent.voiceRoster(entries: []));
    await Future<void>.delayed(Duration.zero);
    expect(controller.voiceIn('lobby'), isEmpty);
  });

  test('text_event_logs_channel_sender_tag_and_id', () async {
    final logged = <String>[];
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logged.add(message ?? '');
    addTearDown(() => debugPrint = print);
    final events = StreamController<AppNodeEvent>();
    final controller = NodeController(eventsOverride: events.stream);
    addTearDown(controller.dispose);
    addTearDown(events.close);

    events.add(AppNodeEvent.text(
        message: AppTextMessage(
            channel: 'general',
            term: BigInt.two,
            seq: BigInt.from(5),
            from: 'ab12${'0' * 60}',
            sentMs: BigInt.zero,
            body: 'hi',
            clientId: BigInt.one)));
    await Future<void>.delayed(Duration.zero);

    expect(logged, contains('hubbub: Text #general from=AB12 seq=2.5'));
  });
}
