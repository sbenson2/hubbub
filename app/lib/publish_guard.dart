/// One track to publish: [publish] returns the publication id, [stop] ends its capture.
class PublishStep {
  const PublishStep({required this.publish, required this.stop});
  final Future<String> Function() publish;
  final Future<void> Function() stop;
}

/// Publishes every step in order, or none: when one throws, the ones already published are
/// unpublished, every capture is stopped, and the error is rethrown, so the button state
/// (off) matches reality (nothing live, no camera light).
Future<void> publishAllOrNone(
  List<PublishStep> steps, {
  required Future<void> Function(String id) unpublish,
}) async {
  final published = <String>[];
  try {
    for (final s in steps) {
      published.add(await s.publish());
    }
  } catch (_) {
    for (final id in published) {
      try {
        await unpublish(id);
      } catch (_) {}
    }
    for (final s in steps) {
      try {
        await s.stop();
      } catch (_) {}
    }
    rethrow;
  }
}
