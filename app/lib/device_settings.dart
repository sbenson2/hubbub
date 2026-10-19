import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
      await File(path).writeAsString(jsonEncode(p.toJson()));
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

  DevicePrefs get prefs => _prefs;

  Future<void> start() async {
    _prefs = await _store.load();
    _sub = _room.devicesChanged.listen((_) => unawaited(_refresh(apply: true)));
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
    _prefs = _prefs.with_(k, d == null ? null : DeviceChoice(d.id, labelOf(d)));
    notifyListeners();
    await _store.save(_prefs);
    await _push(k, force: true);
  }

  /// Before a join: make the adapter use the saved choices that are present right now.
  Future<void> applyForJoin() async {
    await _refresh(apply: false);
    for (final k in DeviceKind.values) {
      await _push(k, force: true);
    }
  }

  Future<void> _refresh({required bool apply}) async {
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
        await _push(k, force: false);
      }
    }
  }

  Future<void> _push(DeviceKind k, {required bool force}) async {
    final id = selected(k)?.id;
    if (!force && _applied.containsKey(k) && _applied[k] == id) return;
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
    } catch (e) {
      debugPrint('could not switch $k: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
