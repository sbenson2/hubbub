import 'dart:async';

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
    test('the stream replay arriving before the launch link resolves opens it once', () async {
      final got = <String>[];
      final src = _SlowSource();
      final router = LinkRouter(src, (l) async {
        got.add(l);
        await Completer<void>().future; // the dialog stays open
      });
      final started = router.start();
      src.replay.add('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      router.markReady(); // the replay opens the link
      expect(got, ['hubbub://join/a']);
      src.first.complete('hubbub://join/a'); // now the launch link resolves
      await started;
      expect(got, ['hubbub://join/a']);
      router.dispose();
    });

    test('the same link opens again once its flow has ended', () async {
      final got = <String>[];
      final src = FakeLinks();
      var done = Completer<void>();
      final router = LinkRouter(src, (l) {
        got.add(l);
        return done.future;
      })..markReady();
      await router.start();
      src.send('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      src.send('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      expect(got.length, 1);
      done.complete();
      await Future<void>.delayed(Duration.zero);
      done = Completer<void>();
      src.send('hubbub://join/a');
      await Future<void>.delayed(Duration.zero);
      expect(got.length, 2);
      router.dispose();
    });

    test('the launch link replayed on the stream is delivered once', () async {
      final got = <String>[];
      final src = FakeLinks(initialLink: 'hubbub://join/a');
      final router = LinkRouter(src, (l) {
        got.add(l);
        return Completer<void>().future; // its dialog stays open
      });
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

/// A source whose launch link resolves when the test says so.
class _SlowSource implements LinkSource {
  final first = Completer<String?>();
  final replay = StreamController<String>.broadcast();

  @override
  Future<String?> initial() => first.future;

  @override
  Stream<String> get stream => replay.stream;
}
