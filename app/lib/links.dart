import 'dart:async';

import 'package:app_links/app_links.dart';

/// Where invite links come from: the link that launched the app, plus links
/// sent to the running app (Windows second launch, macOS `open hubbub://…`).
abstract class LinkSource {
  Future<String?> initial();
  Stream<String> get stream;
}

class AppLinkSource implements LinkSource {
  AppLinkSource([AppLinks? links]) : _links = links ?? AppLinks();

  final AppLinks _links;

  @override
  Future<String?> initial() async => (await _links.getInitialLink())?.toString();

  /// Links that arrive while the app runs. On Windows the plugin also replays
  /// the launch link here, so [LinkQueue] ignores a link already waiting.
  @override
  Stream<String> get stream => _links.uriLinkStream.map((u) => u.toString());
}

/// Holds links until the app is ready for them (a profile name is set), then
/// hands them over in arrival order. Links added after that go straight
/// through.
class LinkQueue {
  LinkQueue(this._onLink);

  final void Function(String link) _onLink;
  final List<String> _pending = [];
  bool _ready = false;

  void add(String link) {
    if (_ready) {
      _onLink(link);
    } else if (!_pending.contains(link)) {
      _pending.add(link);
    }
  }

  /// Call once the name is set. Flushes everything that waited.
  void markReady() {
    if (_ready) return;
    _ready = true;
    final waiting = List<String>.of(_pending);
    _pending.clear();
    waiting.forEach(_onLink);
  }

  /// Back to waiting, e.g. if the name is cleared.
  void markNotReady() => _ready = false;
}

/// Feeds a [LinkSource] into [onLink], holding links until [markReady]. app_links replays the
/// launch link on first listen, so a stream event equal to the link delivered last is dropped.
class LinkRouter {
  LinkRouter(this._source, void Function(String link) onLink) {
    _queue = LinkQueue((link) {
      _last = link;
      onLink(link);
    });
  }

  final LinkSource _source;
  late final LinkQueue _queue;
  StreamSubscription<String>? _sub;
  String? _last;
  bool _disposed = false;

  /// Starts listening. The stream is attached first so no link is missed while the launch
  /// link is read.
  Future<void> start() async {
    _sub = _source.stream.listen((link) {
      if (link != _last) _queue.add(link);
    });
    final first = await _source.initial();
    if (first != null && !_disposed) _queue.add(first);
  }

  /// Call once the profile name is set.
  void markReady() => _queue.markReady();

  void dispose() {
    _disposed = true;
    _sub?.cancel();
  }
}
