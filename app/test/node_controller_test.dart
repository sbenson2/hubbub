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
