import 'dart:io';

var _writes = 0;
final _queues = <String, Future<void>>{};

/// Writes [text] to [path] so a crash or a second writer never leaves half a file: a temp
/// file beside it, then a rename over the target (like the core's `save_atomic`). Writes to
/// one path run one after another, because Windows refuses two renames onto the same file.
Future<void> writeFileAtomic(String path, String text) {
  final turn = (_queues[path] ?? Future<void>.value()).catchError((_) {}).then((_) => _write(path, text));
  _queues[path] = turn;
  return turn;
}

Future<void> _write(String path, String text) async {
  final tmp = File('$path.${pid}_${_writes++}.tmp');
  try {
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(path);
  } catch (_) {
    try {
      await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}
