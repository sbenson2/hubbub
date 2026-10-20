import 'dart:convert';
import 'dart:io';

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'atomic_file.dart';
import 'audio_diagnostics.dart';
import 'capture_options.dart';
import 'room_adapter.dart';

/// Audio levels of this machine: the output master volume, per person a volume and a local mute,
/// and for your own microphone the input volume and the noise suppressor.
class AudioPrefs {
  const AudioPrefs({
    this.master = 1,
    this.volumes = const {},
    this.muted = const {},
    this.inputGain = 1,
    this.noiseSuppression = NoiseSuppression.rnnoise,
    this.lowLightFullFrameRate = true,
  });
  final double master;
  final Map<String, double> volumes;
  final Set<String> muted;

  /// Microphone gain, 0 to [maxVolume] (Discord's Input Volume).
  final double inputGain;
  final NoiseSuppression noiseSuppression;

  /// Windows webcams: stop the camera slowing down in dim light (on by default).
  final bool lowLightFullFrameRate;

  AudioPrefs copyWith({
    double? master,
    Map<String, double>? volumes,
    Set<String>? muted,
    double? inputGain,
    NoiseSuppression? noiseSuppression,
    bool? lowLightFullFrameRate,
  }) =>
      AudioPrefs(
        master: master ?? this.master,
        volumes: volumes ?? this.volumes,
        muted: muted ?? this.muted,
        inputGain: inputGain ?? this.inputGain,
        noiseSuppression: noiseSuppression ?? this.noiseSuppression,
        lowLightFullFrameRate: lowLightFullFrameRate ?? this.lowLightFullFrameRate,
      );

  Map<String, Object?> toJson() => {
        'master': master,
        'volumes': volumes,
        'muted': muted.toList(),
        'inputGain': inputGain,
        'noiseSuppression': noiseSuppression.name,
        'lowLightFullFrameRate': lowLightFullFrameRate,
      };

  static AudioPrefs fromJson(Object? j) {
    if (j is! Map) return const AudioPrefs();
    double level(Object? v) => v is num ? v.toDouble().clamp(0.0, maxVolume) : 1;
    final volumes = j['volumes'], muted = j['muted'];
    return AudioPrefs(
      master: level(j['master']),
      inputGain: level(j['inputGain']),
      noiseSuppression: NoiseSuppression.fromName(j['noiseSuppression']),
      lowLightFullFrameRate: j['lowLightFullFrameRate'] is bool ? j['lowLightFullFrameRate'] as bool : true,
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

  /// The folder this machine's settings live in (null for the in-memory store).
  String? get dataDir => _path == null ? null : File(_path).parent.path;

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
      await writeFileAtomic(path, jsonEncode(p.toJson()));
    } catch (e) {
      debugPrint('could not save audio levels: $e');
    }
  }
}

/// The output volumes and input processing, saved choices, and pushing them to the media room.
class AudioSettings extends ChangeNotifier {
  AudioSettings(this._room, this._store, {String? diagnosticsDir, bool? diagnosticsSupported})
      : diagnosticsSupported = diagnosticsSupported ?? const PluginTapBackend().supported,
        _diagnosticsBase = diagnosticsDir ??
            '${_store.dataDir ?? Directory.systemTemp.path}${Platform.pathSeparator}audio-diagnostics' {
    _reports = _room.audioDiagnosticsReports.listen((r) {
      _lastReport = r;
      _reportSerial++;
      if (!_disposed) notifyListeners();
    });
  }

  final RoomAdapter _room;
  final AudioPrefsStore _store;
  AudioPrefs _prefs = const AudioPrefs();
  bool _disposed = false;

  // Diagnostics recorder: deliberately NOT in [AudioPrefs]. It is never saved, so it is off
  // again after every restart (privacy: nobody leaves call recording on by accident).
  final String _diagnosticsBase;
  late final StreamSubscription<AudioDiagnosticsReport> _reports;
  bool _recordDiagnostics = false;
  AudioDiagnosticsReport? _lastReport;
  int _reportSerial = 0;
  String? _diagnosticsError;

  // Sliders fire many changes a second; the room hears at most one per key every 50 ms, and
  // the last value is always delivered (by the timer, or at once by [commit]).
  static const _throttle = Duration(milliseconds: 50);
  final _lastPush = <String, DateTime>{};
  final _pending = <String, Future<void> Function()>{};
  Timer? _flushTimer;

  double get master => _prefs.master;
  double volumeOf(String id) => _prefs.volumes[id] ?? 1;
  bool isLocallyMuted(String id) => _prefs.muted.contains(id);

  double get inputGain => _prefs.inputGain;
  NoiseSuppression get noiseSuppression => _prefs.noiseSuppression;
  bool get lowLightFullFrameRate => _prefs.lowLightFullFrameRate;

  /// The recorder needs the desktop plugin (Windows, Linux); elsewhere the setting is hidden.
  final bool diagnosticsSupported;

  /// Whether call audio is being recorded to files for diagnostics. Off at every start.
  bool get recordDiagnostics => _recordDiagnostics;

  /// Where the recordings go.
  String get diagnosticsBase => _diagnosticsBase;

  /// The latest finished recording, and a counter that changes with each new one.
  AudioDiagnosticsReport? get lastReport => _lastReport;
  int get reportSerial => _reportSerial;

  /// Switches the diagnostics recorder. While on, the call's audio is written to a new folder
  /// under [diagnosticsBase]; switching it off (or the call ending) produces a report.
  Future<void> setRecordDiagnostics(bool on) async {
    if (on == _recordDiagnostics) return;
    _recordDiagnostics = on;
    _diagnosticsError = null;
    notifyListeners();
    try {
      await _room.setAudioDiagnosticsDir(on ? _diagnosticsBase : null);
    } catch (e) {
      debugPrint('could not switch the diagnostics recorder: $e');
      if (_disposed) return;
      // A recording that could not be stopped may still be writing: the switch and the red
      // badge stay on, with the error, and switching off again tries again.
      if (!on) _recordDiagnostics = true;
      _diagnosticsError = '$e';
      notifyListeners();
    }
  }

  /// Why the last switch of the recorder failed (null: it did not).
  String? get diagnosticsError => _diagnosticsError;

  /// The peaks of your own microphone for the settings meter.
  Stream<MicLevels> get micLevels => _room.micLevels;

  Future<void> start() async {
    final loaded = await _store.load();
    if (_disposed) return;
    _prefs = loaded;
    notifyListeners();
    await applyForJoin();
  }

  Future<void> setMaster(double v) async {
    _prefs = _prefs.copyWith(master: v.clamp(0.0, maxVolume));
    notifyListeners();
    await _throttled('master', () => _room.setMasterVolume(master.clamp(0.0, maxVolume)));
  }

  Future<void> setVolume(String id, double v) async {
    final level = v.clamp(0.0, maxVolume);
    _prefs = _prefs.copyWith(volumes: {..._prefs.volumes, id: level});
    notifyListeners();
    await _throttled('volume:$id', () => _room.setParticipantVolume(id, level));
  }

  /// Local only: you stop hearing [id]; nobody else is told.
  Future<void> setLocalMute(String id, bool muted) async {
    _prefs = _prefs.copyWith(
        muted: muted ? {..._prefs.muted, id} : ({..._prefs.muted}..remove(id)));
    notifyListeners();
    await _push(() => _room.setLocalMuteFor(id, muted));
    await commit(); // a mute is a click, not a drag
  }

  /// Your microphone gain (0 to [maxVolume]); like the output sliders it reaches the capture
  /// path while dragging (throttled) and is saved by [commit].
  Future<void> setInputGain(double v) async {
    _prefs = _prefs.copyWith(inputGain: v.clamp(0.0, maxVolume));
    notifyListeners();
    await _throttled('input-gain', () => _room.setInputGain(inputGain));
  }

  Future<void> setNoiseSuppression(NoiseSuppression ns) async {
    _prefs = _prefs.copyWith(noiseSuppression: ns);
    notifyListeners();
    await _push(() => _room.setNoiseSuppression(ns));
    await commit(); // a choice, not a drag
  }

  Future<void> setLowLightFullFrameRate(bool on) async {
    _prefs = _prefs.copyWith(lowLightFullFrameRate: on);
    notifyListeners();
    await _push(() => _room.setLowLightFullFrameRate(on));
    await commit();
  }

  /// Saves what the sliders now show; called when a drag ends.
  Future<void> commit() async {
    await _flush();
    await _store.save(_prefs);
  }

  Future<void> _throttled(String key, Future<void> Function() call) async {
    final now = DateTime.now();
    final last = _lastPush[key];
    if (last == null || now.difference(last) >= _throttle) {
      _lastPush[key] = now;
      _pending.remove(key);
      await _push(call);
      return;
    }
    _pending[key] = call;
    _flushTimer ??= Timer(_throttle, _flush);
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final calls = _pending.values.toList();
    _pending.clear();
    for (final c in calls) {
      await _push(c);
    }
  }

  /// Before a join (and once the saved levels are loaded): hand every level to the room. The
  /// adapter keeps them across calls too; this makes a fresh room agree with the saved state.
  Future<void> applyForJoin() async {
    await _push(() => _room.setNoiseSuppression(noiseSuppression));
    await _push(() => _room.setLowLightFullFrameRate(lowLightFullFrameRate));
    await _push(() => _room.setInputGain(inputGain));
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
    if (_recordDiagnostics) {
      _recordDiagnostics = false;
      unawaited(_room.setAudioDiagnosticsDir(null).catchError((Object _) {}));
    }
    unawaited(_reports.cancel());
    _flushTimer?.cancel();
    super.dispose();
  }
}
