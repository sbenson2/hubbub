import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'room_adapter.dart';

/// Output levels of this machine: the master volume, and per person a volume and a local mute.
class AudioPrefs {
  const AudioPrefs({this.master = 1, this.volumes = const {}, this.muted = const {}});
  final double master;
  final Map<String, double> volumes;
  final Set<String> muted;

  Map<String, Object?> toJson() => {'master': master, 'volumes': volumes, 'muted': muted.toList()};

  static AudioPrefs fromJson(Object? j) {
    if (j is! Map) return const AudioPrefs();
    double level(Object? v) => v is num ? v.toDouble().clamp(0.0, maxVolume) : 1;
    final volumes = j['volumes'], muted = j['muted'];
    return AudioPrefs(
      master: level(j['master']),
      volumes: volumes is Map
          ? {for (final e in volumes.entries) if (e.key is String) e.key as String: level(e.value)}
          : const {},
      muted: muted is List ? {for (final m in muted) if (m is String) m} : const {},
    );
  }
}

/// Where the levels live: a small JSON file in this machine's data root, never synced.
class AudioPrefsStore {
  AudioPrefsStore.file(String this._path) : _memory = null;
  AudioPrefsStore.memory([AudioPrefs? initial])
      : _path = null,
        _memory = initial ?? const AudioPrefs();

  final String? _path;
  AudioPrefs? _memory;

  Future<AudioPrefs> load() async {
    final path = _path;
    if (path == null) return _memory!;
    try {
      return AudioPrefs.fromJson(jsonDecode(await File(path).readAsString()));
    } catch (_) {
      return const AudioPrefs(); // missing or unreadable: everything at 100%
    }
  }

  Future<void> save(AudioPrefs p) async {
    final path = _path;
    if (path == null) {
      _memory = p;
      return;
    }
    try {
      await File(path).writeAsString(jsonEncode(p.toJson()));
    } catch (e) {
      debugPrint('could not save audio levels: $e');
    }
  }
}

/// The output volumes, saved choices, and pushing them to the media room.
class AudioSettings extends ChangeNotifier {
  AudioSettings(this._room, this._store);

  final RoomAdapter _room;
  final AudioPrefsStore _store;
  AudioPrefs _prefs = const AudioPrefs();
  bool _disposed = false;

  double get master => _prefs.master;
  double volumeOf(String id) => _prefs.volumes[id] ?? 1;
  bool isLocallyMuted(String id) => _prefs.muted.contains(id);

  /// The level of your own microphone for the settings meter.
  Stream<double> get inputLevel => _room.inputLevel;

  Future<void> start() async {
    final loaded = await _store.load();
    if (_disposed) return;
    _prefs = loaded;
    notifyListeners();
    await applyForJoin();
  }

  Future<void> setMaster(double v) async {
    _prefs = AudioPrefs(
        master: v.clamp(0.0, maxVolume), volumes: _prefs.volumes, muted: _prefs.muted);
    notifyListeners();
    await _push(() => _room.setMasterVolume(master));
  }

  Future<void> setVolume(String id, double v) async {
    final level = v.clamp(0.0, maxVolume);
    _prefs = AudioPrefs(
        master: master, volumes: {..._prefs.volumes, id: level}, muted: _prefs.muted);
    notifyListeners();
    await _push(() => _room.setParticipantVolume(id, level));
  }

  /// Local only: you stop hearing [id]; nobody else is told.
  Future<void> setLocalMute(String id, bool muted) async {
    _prefs = AudioPrefs(
        master: master,
        volumes: _prefs.volumes,
        muted: muted ? {..._prefs.muted, id} : ({..._prefs.muted}..remove(id)));
    notifyListeners();
    await _push(() => _room.setLocalMuteFor(id, muted));
    await commit(); // a mute is a click, not a drag
  }

  /// Saves what the sliders now show; called when a drag ends.
  Future<void> commit() => _store.save(_prefs);

  /// Before a join (and once the saved levels are loaded): hand every level to the room. The
  /// adapter keeps them across calls too; this makes a fresh room agree with the saved state.
  Future<void> applyForJoin() async {
    await _push(() => _room.setMasterVolume(master));
    for (final e in _prefs.volumes.entries) {
      await _push(() => _room.setParticipantVolume(e.key, e.value));
    }
    for (final id in _prefs.muted) {
      await _push(() => _room.setLocalMuteFor(id, true));
    }
  }

  Future<void> _push(Future<void> Function() call) async {
    try {
      await call();
    } catch (e) {
      debugPrint('could not set a volume: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
