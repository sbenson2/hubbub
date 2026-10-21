/// Keeps a participant "speaking" for [hold] after the server last reported them speaking.
/// The server decides in short windows (so the ring lights quickly) and drops at once, which
/// would flicker between words; the hold bridges those gaps.
class SpeakingHold {
  SpeakingHold({this.hold = const Duration(milliseconds: 400), DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  final Duration hold;
  final DateTime Function() _now;
  final _until = <String, DateTime>{};

  /// Whether [id] counts as speaking, given the server's current word [raw] on them.
  bool update(String id, bool raw) {
    final now = _now();
    if (raw) {
      _until[id] = now.add(hold);
      return true;
    }
    final until = _until[id];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _until.remove(id);
    return false;
  }

  /// The earliest time a running hold ends, or null when none is running.
  DateTime? get nextExpiry {
    DateTime? first;
    for (final t in _until.values) {
      if (first == null || t.isBefore(first)) first = t;
    }
    return first;
  }

  /// Forgets everyone not in [ids] (they left).
  void retainOnly(Set<String> ids) => _until.removeWhere((id, _) => !ids.contains(id));

  void clear() => _until.clear();
}
