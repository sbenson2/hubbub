import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/share_sources.dart';

/// The portal loader with a fake capturer: [pictureAfter] polls pass before a picture shows.
class _Portal {
  _Portal({this.pictureAfter, this.screens = const ['portal-1']});
  final int? pictureAfter;
  final List<String> screens;
  int listed = 0;
  int released = 0;
  Object? releaseError;
  Object? listError;
  final polled = <String>[];

  Future<void> release() async {
    released++;
    if (releaseError != null) throw releaseError!;
  }

  Future<List<ShareSource>> list() async {
    listed++;
    if (listError != null) throw listError!;
    return [for (final id in screens) ShareSource(id: id, name: 'Screen', kind: ShareKind.screen)];
  }

  Future<Uint8List?> thumbnail(String id) async {
    polled.add(id);
    return pictureAfter != null && polled.length > pictureAfter! ? Uint8List.fromList([1, 2, 3]) : Uint8List(0);
  }
}

void main() {
  testWidgets('the_portal_source_waits_for_the_users_pick_then_returns_the_screen_id', (tester) async {
    final portal = _Portal(pictureAfter: 3);
    String? id;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail, release: portal.release)
        .then((v) => id = v);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(id, isNull, reason: 'no picture yet: still in the system dialog');
    await tester.pump(const Duration(milliseconds: 1500));
    expect(id, 'portal-1');
    expect(portal.released, 0, reason: 'a pick keeps its session: the share is built on it');
    expect(portal.listed, 1, reason: 'one listing: it opens the system dialog, so never repeat it');
    expect(portal.polled.toSet(), {'portal-1'});
    // About every 500 ms.
    expect(portal.polled.length, inInclusiveRange(4, 6));
  });

  testWidgets('cancelling_in_hubbub_stops_the_wait_and_returns_null', (tester) async {
    final portal = _Portal();
    final cancel = PortalCancel();
    var done = false;
    String? id = 'unset';
    portalScreenSource(cancel, list: portal.list, thumbnail: portal.thumbnail, release: portal.release).then((v) {
      id = v;
      done = true;
    });
    await tester.pump(const Duration(seconds: 2));
    expect(done, isFalse);
    cancel.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(id, isNull);
    expect(portal.released, 1, reason: 'a Hubbub cancel closes the session, and so the system dialog');
    final polls = portal.polled.length;
    await tester.pump(const Duration(seconds: 5));
    expect(portal.polled.length, polls, reason: 'polling stops after the cancel');
  });

  testWidgets('no_pick_for_two_minutes_times_out', (tester) async {
    final portal = _Portal();
    Object? error;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail, release: portal.release)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump(const Duration(seconds: 119));
    expect(error, isNull);
    expect(portal.released, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(error, isA<TimeoutException>());
    expect((error as TimeoutException).message, contains('No screen was chosen'));
    expect((error as TimeoutException).message, isNot(contains('cancel')));
    expect(portal.released, 1, reason: 'a timeout closes the session too');
  });

  testWidgets('a_portal_with_no_screen_is_an_error', (tester) async {
    final portal = _Portal(screens: const []);
    Object? error;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail, release: portal.release)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump();
    expect(error, isA<StateError>());
    expect(portal.released, 1);
  });

  testWidgets('a_listing_that_fails_releases_the_session', (tester) async {
    final portal = _Portal()..listError = StateError('no portal');
    Object? error;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail, release: portal.release)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump();
    expect(error, isA<StateError>());
    expect(portal.released, 1);
  });

  testWidgets('a_release_that_fails_is_ignored', (tester) async {
    final portal = _Portal()..releaseError = StateError('plugin gone');
    final cancel = PortalCancel();
    var done = false;
    String? id = 'unset';
    portalScreenSource(cancel, list: portal.list, thumbnail: portal.thumbnail, release: portal.release).then((v) {
      id = v;
      done = true;
    });
    await tester.pump(const Duration(seconds: 1));
    cancel.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(id, isNull);
    expect(portal.released, 1);
  });

  testWidgets('five_failing_thumbnail_calls_in_a_row_end_the_wait_with_that_error', (tester) async {
    final portal = _Portal();
    Object? error;
    var calls = 0;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: (s) async {
      calls++;
      throw StateError('Failed to get desktop source thumbnail');
    }, release: portal.release)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump(const Duration(seconds: 10));
    expect(error, isA<StateError>(), reason: 'no waiting out the two minutes');
    expect(calls, portalMaxErrors);
    expect(portal.released, 1);
  });

  testWidgets('a_success_between_failures_resets_the_error_count', (tester) async {
    final portal = _Portal();
    var calls = 0;
    Object? error;
    String? id;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: (s) async {
      calls++;
      // 4 failures, one empty answer, 4 failures, then the picture.
      if (calls == 5) return Uint8List(0);
      if (calls == 10) return Uint8List.fromList([1]);
      throw StateError('not ready');
    }, release: portal.release)
        .then((v) => id = v, onError: (Object e) { error = e; });
    await tester.pump(const Duration(seconds: 10));
    expect(error, isNull);
    expect(id, 'portal-1');
  });

  testWidgets('the_screens_are_listed_once_per_attempt_even_when_thumbnail_calls_fail', (tester) async {
    final portal = _Portal();
    var calls = 0;
    String? id;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: (s) async {
      if (calls++ < 4) throw StateError('not ready');
      return Uint8List.fromList([1]);
    }, release: portal.release)
        .then((v) => id = v);
    await tester.pump(const Duration(seconds: 10));
    expect(id, 'portal-1');
    expect(portal.listed, 1, reason: 'every listing would open another system prompt');
  });

  testWidgets('a_thumbnail_call_that_fails_is_tried_again', (tester) async {
    final portal = _Portal(pictureAfter: 0);
    var calls = 0;
    String? id;
    portalScreenSource(PortalCancel(), list: portal.list, release: portal.release, thumbnail: (s) {
      if (calls++ < 2) throw StateError('not ready');
      return portal.thumbnail(s);
    }).then((v) => id = v);
    await tester.pump(const Duration(seconds: 3));
    expect(id, 'portal-1');
  });
}
