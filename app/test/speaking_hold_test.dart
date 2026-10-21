import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/speaking_hold.dart';

void main() {
  late DateTime now;
  late SpeakingHold h;
  setUp(() {
    now = DateTime(2026, 1, 1);
    h = SpeakingHold(clock: () => now);
  });
  void advance(int ms) => now = now.add(Duration(milliseconds: ms));

  test('turns_on_immediately', () {
    expect(h.update('a', false), isFalse);
    expect(h.update('a', true), isTrue);
  });

  test('stays_on_through_a_gap_under_400ms', () {
    h.update('a', true);
    advance(399);
    expect(h.update('a', false), isTrue);
  });

  test('goes_off_after_400ms_and_stays_off', () {
    h.update('a', true);
    advance(400);
    expect(h.update('a', false), isFalse);
    expect(h.nextExpiry, isNull);
  });

  test('speech_again_restarts_the_hold', () {
    h.update('a', true);
    advance(300);
    h.update('a', true);
    advance(300);
    expect(h.update('a', false), isTrue);
  });

  test('reports_the_earliest_expiry', () {
    expect(h.nextExpiry, isNull);
    h.update('a', true);
    advance(100);
    h.update('b', true);
    expect(h.nextExpiry, DateTime(2026, 1, 1, 0, 0, 0, 400));
  });

  test('forgets_participants_who_leave', () {
    h.update('a', true);
    h.update('b', true);
    h.retainOnly({'b'});
    expect(h.update('a', false), isFalse);
    h.clear();
    expect(h.nextExpiry, isNull);
  });
}
