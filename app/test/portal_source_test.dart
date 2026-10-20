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
  final polled = <String>[];

  Future<List<ShareSource>> list() async {
    listed++;
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
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail).then((v) => id = v);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(id, isNull, reason: 'no picture yet: still in the system dialog');
    await tester.pump(const Duration(milliseconds: 1500));
    expect(id, 'portal-1');
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
    portalScreenSource(cancel, list: portal.list, thumbnail: portal.thumbnail).then((v) {
      id = v;
      done = true;
    });
    await tester.pump(const Duration(seconds: 2));
    expect(done, isFalse);
    cancel.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(id, isNull);
    final polls = portal.polled.length;
    await tester.pump(const Duration(seconds: 5));
    expect(portal.polled.length, polls, reason: 'polling stops after the cancel');
  });

  testWidgets('no_pick_for_two_minutes_times_out', (tester) async {
    final portal = _Portal();
    Object? error;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump(const Duration(seconds: 119));
    expect(error, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(error, isA<TimeoutException>());
  });

  testWidgets('a_portal_with_no_screen_is_an_error', (tester) async {
    final portal = _Portal(screens: const []);
    Object? error;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: portal.thumbnail)
        .then((_) {}, onError: (Object e) { error = e; });
    await tester.pump();
    expect(error, isA<StateError>());
  });

  testWidgets('a_thumbnail_call_that_fails_is_tried_again', (tester) async {
    final portal = _Portal(pictureAfter: 0);
    var calls = 0;
    String? id;
    portalScreenSource(PortalCancel(), list: portal.list, thumbnail: (s) {
      if (calls++ < 2) throw StateError('not ready');
      return portal.thumbnail(s);
    }).then((v) => id = v);
    await tester.pump(const Duration(seconds: 3));
    expect(id, 'portal-1');
  });
}
