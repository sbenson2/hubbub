import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/links.dart';

import 'support/fakes.dart';

void main() {
  test('links wait for ready, then flush in order', () {
    final got = <String>[];
    final q = LinkQueue(got.add);
    q.add('hubbub://join/a');
    q.add('hubbub://join/b');
    expect(got, isEmpty);
    q.markReady();
    expect(got, ['hubbub://join/a', 'hubbub://join/b']);
    q.markReady();
    expect(got.length, 2);
  });

  test('a repeat of a waiting link is dropped', () {
    final got = <String>[];
    final q = LinkQueue(got.add);
    q.add('hubbub://join/a');
    q.add('hubbub://join/a');
    q.markReady();
    expect(got, ['hubbub://join/a']);
  });

  test('links after ready go straight through', () {
    final got = <String>[];
    final q = LinkQueue(got.add)..markReady();
    q.add('hubbub://join/c');
    expect(got, ['hubbub://join/c']);
  });

  test('markNotReady holds links again', () {
    final got = <String>[];
    final q = LinkQueue(got.add)..markReady();
    q.markNotReady();
    q.add('hubbub://join/d');
    expect(got, isEmpty);
    q.markReady();
    expect(got, ['hubbub://join/d']);
  });

  group('LinkRouter', () {
    test('the launch link replayed on the stream is delivered once', () async {
      final got = <String>[];
      final src = FakeLinks(initialLink: 'hubbub://join/a');
      final router = LinkRouter(src, got.add);
      await router.start();
      src.send('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      router.markReady();
      expect(got, ['hubbub://join/a']);
      src.send('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      expect(got, ['hubbub://join/a']);
      src.send('hubbub://join/b');
      await Future<void>.delayed(Duration.zero);
      expect(got, ['hubbub://join/a', 'hubbub://join/b']);
      router.dispose();
    });

    test('links wait for markReady', () async {
      final got = <String>[];
      final src = FakeLinks();
      final router = LinkRouter(src, got.add);
      await router.start();
      src.send('hubbub://join/c');
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      router.markReady();
      expect(got, ['hubbub://join/c']);
      router.dispose();
    });
  });
}
