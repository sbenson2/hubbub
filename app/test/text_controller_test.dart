import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/src/rust/api/hubbub.dart';
import 'package:hubbub/text_controller.dart';

import 'support/fakes.dart';

void main() {
  final me = memberIdFor('aaaa');
  final bob = memberIdFor('bbbb');

  late StreamController<AppNodeEvent> events;
  late FakeTextService service;
  late TextController text;

  setUp(() {
    events = StreamController<AppNodeEvent>();
    service = FakeTextService();
    text = TextController(service: service, events: events.stream, me: () => me);
  });
  tearDown(() async {
    text.dispose();
    await events.close();
  });

  Future<void> deliver(AppTextMessage m) async {
    events.add(AppNodeEvent.text(message: m));
    await pumpEventQueue();
  }

  test('own_delivery_after_send_returns_turns_pending_into_delivered', () async {
    text.open('general');
    await text.send('general', 'hello');
    final pending = text.messages('general').single;
    expect(pending.delivery, Delivery.pending);
    expect(pending.clientId, BigInt.from(100));

    await deliver(textMessage(from: me, clientId: 100, body: 'hello'));

    final shown = text.messages('general');
    expect(shown, hasLength(1));
    expect(shown.single.delivery, Delivery.delivered);
  });

  test('own_delivery_before_send_returns_is_shown_once_as_delivered', () async {
    service.holdSends = true;
    text.open('general');
    final sending = text.send('general', 'hello');
    await pumpEventQueue();
    expect(text.messages('general').single.delivery, Delivery.pending);

    // On the host, the Text event can beat node_send_text's return.
    await deliver(textMessage(from: me, clientId: 100, body: 'hello'));
    service.held.single.complete(BigInt.zero);
    await sending;

    final shown = text.messages('general');
    expect(shown, hasLength(1));
    expect(shown.single.delivery, Delivery.delivered);
    expect(shown.single.clientId, BigInt.from(100));
  });

  test('a_repeat_of_a_shown_key_is_ignored', () async {
    text.open('general');
    await deliver(textMessage(from: bob, clientId: 7, body: 'once'));
    await deliver(textMessage(from: bob, clientId: 7, body: 'once', term: 2, seq: 9));

    expect(text.messages('general').map((m) => m.body), ['once']);
  });

  test('live_messages_keep_arrival_order_not_term_seq', () async {
    text.open('general');
    // A full restart starts terms again at 1: arrival order still wins.
    await deliver(textMessage(from: bob, clientId: 1, body: 'first', term: 5, seq: 3));
    await deliver(textMessage(from: bob, clientId: 2, body: 'second', term: 1, seq: 1));

    expect(text.messages('general').map((m) => m.body), ['first', 'second']);
  });

  test('history_merges_with_live_events_by_sender_and_client_id', () async {
    service.history['general'] = [
      textMessage(from: bob, clientId: 1, body: 'old'),
      textMessage(from: bob, clientId: 2, body: 'overlap'),
    ];
    // A live event that the history load also returns.
    await deliver(textMessage(from: bob, clientId: 2, body: 'overlap'));
    await deliver(textMessage(from: bob, clientId: 3, body: 'new'));

    text.open('general');
    await pumpEventQueue();

    expect(text.messages('general').map((m) => m.body), ['old', 'overlap', 'new']);
    expect(text.reachedStart('general'), isTrue);
  });

  test('unread_marks_other_channels_until_opened', () async {
    text.open('general');
    await deliver(textMessage(from: bob, clientId: 1, channel: 'games'));
    await deliver(textMessage(from: bob, clientId: 2, channel: 'general'));
    await deliver(textMessage(from: me, clientId: 3, channel: 'memes'));

    expect(text.isUnread('games'), isTrue);
    expect(text.isUnread('general'), isFalse, reason: 'being viewed');
    expect(text.isUnread('memes'), isFalse, reason: 'my own message');

    text.open('games');
    expect(text.isUnread('games'), isFalse);
  });

  test('a_failed_send_stays_visible_as_failed', () async {
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    addTearDown(() => debugPrint = print);
    final failing = _FailingService();
    final t = TextController(service: failing, events: const Stream.empty(), me: () => me);
    addTearDown(t.dispose);
    t.open('general');
    await t.send('general', 'nope');

    expect(t.messages('general').single.delivery, Delivery.failed);
  });
}

class _FailingService implements TextService {
  @override
  Future<BigInt> sendText(String channel, String body) async => throw StateError('no node');
  @override
  Future<List<AppTextMessage>> textHistory(String channel, int limit) async => const [];
}
