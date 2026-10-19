import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'atomic_file.dart';
import 'room_adapter.dart';

/// A remembered device. The id can change across reboots on some OSes, so the label is kept
/// to find it again.
class DeviceChoice {
  const DeviceChoice(this.id, this.label);
  final String id;
  final String label;

  Map<String, String> toJson() => {'id': id, 'label': label};
  static DeviceChoice? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], label = j['label'];
    return id is String && label is String ? DeviceChoice(id, label) : null;
  }
}

/// The three device choices of this machine (null follows the OS default).
class DevicePrefs {
  const DevicePrefs({this.input, this.output, this.camera});
  final DeviceChoice? input, output, camera;

  DeviceChoice? of(DeviceKind k) => switch (k) {
        DeviceKind.audioInput => input,
        DeviceKind.audioOutput => output,
        DeviceKind.videoInput => camera,
      };

  DevicePrefs with_(DeviceKind k, DeviceChoice? c) => DevicePrefs(
        input: k == DeviceKind.audioInput ? c : input,
        output: k == DeviceKind.audioOutput ? c : output,
        camera: k == DeviceKind.videoInput ? c : camera,
      );

  Map<String, Object?> toJson() =>
      {'input': input?.toJson(), 'output': output?.toJson(), 'camera': camera?.toJson()};

  static DevicePrefs fromJson(Object? j) => j is Map
      ? DevicePrefs(
          input: DeviceChoice.fromJson(j['input']),
          output: DeviceChoice.fromJson(j['output']),
          camera: DeviceChoice.fromJson(j['camera']),
        )
      : const DevicePrefs();
}

/// Where the choices live: a small JSON file in this machine's data root. They are local
/// preferences, never synced.
class DevicePrefsStore {
  DevicePrefsStore.file(String this._path) : _memory = null;
  DevicePrefsStore.memory([DevicePrefs? initial])
      : _path = null,
        _memory = initial ?? const DevicePrefs();

  final String? _path;
  DevicePrefs? _memory;

  Future<DevicePrefs> load() async {
    final path = _path;
    if (path == null) return _memory!;
    try {
      return DevicePrefs.fromJson(jsonDecode(await File(path).readAsString()));
    } catch (_) {
      return const DevicePrefs(); // missing or unreadable: no choices
    }
  }

  Future<void> save(DevicePrefs p) async {
    final path = _path;
    if (path == null) {
      _memory = p;
      return;
    }
    try {
      await writeFileAtomic(path, jsonEncode(p.toJson()));
    } catch (e) {
      debugPrint('could not save device choices: $e');
    }
  }
}

/// The device [c] names: matched by id first, then by label; null when it is not present.
MediaDeviceInfo? matchDevice(DeviceChoice? c, List<MediaDeviceInfo> list) {
  if (c == null) return null;
  for (final d in list) {
    if (d.id == c.id) return d;
  }
  if (c.label.isNotEmpty) {
    for (final d in list) {
      if (d.label == c.label) return d;
    }
  }
  return null;
}

/// The device lists, the saved choices, and pushing the choices to the media room.
class DeviceSettings extends ChangeNotifier {
  DeviceSettings(this._room, this._store);

  final RoomAdapter _room;
  final DevicePrefsStore _store;
  DevicePrefs _prefs = const DevicePrefs();
  List<MediaDeviceInfo> _all = const [];
  StreamSubscription<void>? _sub;
  final _applied = <DeviceKind, String?>{};
  bool _disposed = false;

  /// Why the last switch of a kind failed (shown under its dropdown); cleared by a success.
  final _errors = <DeviceKind, String>{};
  String? errorOf(DeviceKind k) => _errors[k];

  DevicePrefs get prefs => _prefs;

  Future<void> start() async {
    _sub = _room.devicesChanged.listen((_) => unawaited(_refresh(apply: true)));
    final loaded = await _store.load();
    if (_disposed) return;
    _prefs = loaded;
    await _refresh(apply: false);
  }

  List<MediaDeviceInfo> devices(DeviceKind k) => [
        for (final d in _all)
          if (d.kind == k) d
      ];

  /// What the dropdown shows: null is Default (nothing chosen, or the chosen device is away).
  MediaDeviceInfo? selected(DeviceKind k) => matchDevice(_prefs.of(k), devices(k));

  /// A device's name, with a numbered fallback for unlabelled ones.
  String labelOf(MediaDeviceInfo d) {
    if (d.label.isNotEmpty) return d.label;
    final n = devices(d.kind).indexWhere((x) => x.id == d.id) + 1;
    final noun = switch (d.kind) {
      DeviceKind.audioInput => 'Microphone',
      DeviceKind.audioOutput => 'Speaker',
      DeviceKind.videoInput => 'Camera',
    };
    return '$noun $n';
  }

  Future<void> choose(DeviceKind k, MediaDeviceInfo? d) async {
    final before = _prefs;
    // The real label is saved, empty or not: a synthetic "Microphone 2" could never match.
    _prefs = _prefs.with_(k, d == null ? null : DeviceChoice(d.id, d.label));
    _errors.remove(k);
    notifyListeners();
    final err = await _push(k, force: true);
    if (err != null) {
      // Show what is really in use: undo the choice and say so.
      _prefs = before;
      final now = selected(k);
      _errors[k] = "Couldn't switch to ${d == null ? 'Default' : labelOf(d)}. "
          'Still using ${now == null ? 'Default' : labelOf(now)}.';
      await _push(k, force: true); // best effort to put the previous device back
    }
    await _store.save(_prefs);
    if (!_disposed) notifyListeners();
  }

  /// Before a join: make the adapter use the saved choices that are present right now.
  Future<void> applyForJoin() async {
    await _refresh(apply: false);
    for (final k in DeviceKind.values) {
      await _push(k, force: true);
    }
  }

  Future<void> _refresh({required bool apply}) async {
    final before = {for (final k in DeviceKind.values) k: _idsOf(k)};
    try {
      _all = await _room.listDevices();
    } catch (e) {
      debugPrint('could not list devices: $e');
      return;
    }
    if (_disposed) return;
    notifyListeners();
    if (apply) {
      // A saved device that came back, or a chosen one that left, changes what is in use.
      for (final k in DeviceKind.values) {
        // Default is "the first device the OS lists" and desktop WebRTC does not follow the OS
        // default by itself: when the list changed (a headset unplugged or added), open
        // Default again so the mic and speaker move with it.
        final followsDefault = k != DeviceKind.videoInput &&
            selected(k) == null &&
            !setEquals(before[k], _idsOf(k));
        await _push(k, force: followsDefault);
      }
    }
  }

  Set<String> _idsOf(DeviceKind k) => {for (final d in devices(k)) d.id};

  /// Null when the adapter took the choice, else the failure.
  Future<Object?> _push(DeviceKind k, {required bool force}) async {
    final id = selected(k)?.id;
    if (!force && _applied.containsKey(k) && _applied[k] == id) return null;
    _applied[k] = id;
    try {
      switch (k) {
        case DeviceKind.audioInput:
          await _room.setInputDevice(id);
        case DeviceKind.audioOutput:
          await _room.setOutputDevice(id);
        case DeviceKind.videoInput:
          await _room.setCameraDevice(id);
      }
      return null;
    } catch (e) {
      debugPrint('could not switch $k: $e');
      return e;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
