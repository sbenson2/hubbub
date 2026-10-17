import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/text_controller.dart';
import 'package:hubbub/ui/text_channel_view.dart';

void main() {
  final alice = 'a' * 64;
  final bob = 'b' * 64;

  ChatMessage msg(String from, DateTime at, [String body = 'x']) =>
      ChatMessage(from: from, clientId: BigInt.one, body: body, sentAt: at);

  /// Which messages start a group, and where day dividers fall, as a compact string.
  String shape(List<MessageRow> rows) => rows
      .map((r) => switch (r) {
            DayDivider(:final day) => '|${day.month}/${day.day}|',
            MessageLine(:final message, :final startsGroup) =>
              '${startsGroup ? 'G' : 'c'}:${message.body}',
          })
      .join(' ');

  test('same_author_within_seven_minutes_groups', () {
    final t = DateTime(2026, 10, 17, 15);
    final rows = groupMessages([
      msg(alice, t, '1'),
      msg(alice, t.add(const Duration(minutes: 3)), '2'),
      msg(alice, t.add(const Duration(minutes: 10)), '3'),
    ]);
    expect(shape(rows), '|10/17| G:1 c:2 c:3');
  });

  test('a_gap_over_seven_minutes_starts_a_new_group', () {
    final t = DateTime(2026, 10, 17, 15);
    final rows = groupMessages([
      msg(alice, t, '1'),
      msg(alice, t.add(const Duration(minutes: 7, seconds: 1)), '2'),
    ]);
    expect(shape(rows), '|10/17| G:1 G:2');
  });

  test('another_author_breaks_the_group', () {
    final t = DateTime(2026, 10, 17, 15);
    final rows = groupMessages([
      msg(alice, t, '1'),
      msg(bob, t.add(const Duration(minutes: 1)), '2'),
      msg(alice, t.add(const Duration(minutes: 2)), '3'),
    ]);
    expect(shape(rows), '|10/17| G:1 G:2 G:3');
  });

  test('a_new_day_adds_a_divider_and_breaks_the_group', () {
    final rows = groupMessages([
      msg(alice, DateTime(2026, 10, 16, 23, 58), '1'),
      msg(alice, DateTime(2026, 10, 17, 0, 1), '2'),
    ]);
    expect(shape(rows), '|10/16| G:1 |10/17| G:2');
  });

  test('timestamps_read_like_discord', () {
    final now = DateTime(2026, 10, 17, 18);
    expect(messageTimestamp(DateTime(2026, 10, 17, 15, 14), now), 'Today at 3:14 PM');
    expect(messageTimestamp(DateTime(2026, 10, 16, 0, 5), now), 'Yesterday at 12:05 AM');
    expect(messageTimestamp(DateTime(2026, 9, 2, 12, 30), now), '09/02/2026 12:30 PM');
    expect(dayDividerLabel(DateTime(2026, 10, 17)), 'October 17, 2026');
  });
}
