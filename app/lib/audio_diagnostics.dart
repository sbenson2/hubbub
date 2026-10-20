import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// The native side of the diagnostic recorder: send-side taps and per-track sinks, each a
/// 48 kHz mono WAV. The real one is the patched flutter_webrtc plugin; tests use a fake.
abstract class AudioTapBackend {
  bool get supported;
  Future<int> startSend(rtc.HubbubSendTap tap, String path);
  Future<rtc.HubbubTapResult?> stopSend(rtc.HubbubSendTap tap);
  Future<int> startTrack(String trackId, String path);
  Future<rtc.HubbubTapResult?> stopTrack(String trackId);
  Future<Map<dynamic, dynamic>?> status();
}

class PluginTapBackend implements AudioTapBackend {
  const PluginTapBackend();
  @override
  bool get supported => rtc.HubbubTaps.supported;
  @override
  Future<int> startSend(rtc.HubbubSendTap tap, String path) => rtc.HubbubTaps.start(tap, path);
  @override
  Future<rtc.HubbubTapResult?> stopSend(rtc.HubbubSendTap tap) => rtc.HubbubTaps.stop(tap);
  @override
  Future<int> startTrack(String trackId, String path) => rtc.HubbubTaps.recordTrack(trackId, path);
  @override
  Future<rtc.HubbubTapResult?> stopTrack(String trackId) => rtc.HubbubTaps.stopTrack(trackId);
  @override
  Future<Map<dynamic, dynamic>?> status() => rtc.HubbubAudio.status();
}

/// Where a finished recording went.
@immutable
class AudioDiagnosticsReport {
  const AudioDiagnosticsReport({required this.directory, required this.files});

  /// The folder holding the WAV files and `session.json`.
  final String directory;

  /// File names (not paths) written, `session.json` included.
  final List<String> files;
}

/// A file name part that is safe on Windows and Linux.
String safeFileName(String s) {
  final t = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'^[._]+|_+$'), '');
  return t.isEmpty ? 'unknown' : (t.length > 40 ? t.substring(0, 40) : t);
}

String _stamp(DateTime t) {
  String p(int v, [int n = 2]) => v.toString().padLeft(n, '0');
  return '${p(t.year, 4)}${p(t.month)}${p(t.day)}-${p(t.hour)}${p(t.minute)}${p(t.second)}';
}

/// One recording: a new folder `<base>/call-audio-<time>` with `send-processed.wav`,
/// `send-hook-input.wav` (the capture signal before Hubbub's processing, the closest to the raw
/// microphone that can be reached), `recv-<name>.wav` per remote participant, and `session.json` (settings and
/// the wall clock each file started, so the files can be aligned).
///
/// Measurement only: it never changes how audio is processed. The native taps copy samples into
/// a ring buffer and a background thread writes the files.
class AudioDiagnosticsSession {
  AudioDiagnosticsSession._(this._backend, this.directory, this.started, this._settings);

  final AudioTapBackend _backend;
  final String directory;
  final DateTime started;
  final Map<String, Object?> _settings;
  final _entries = <String, Map<String, Object?>>{};
  final _trackFiles = <String, String>{}; // track id -> file name
  final _usedNames = <String>{};
  var _stopped = false;

  /// Starts the send taps. [settings] goes into `session.json` (noise suppression mode, input
  /// gain, Opus options when known).
  static Future<AudioDiagnosticsSession?> start({
    required String baseDir,
    required Map<String, Object?> settings,
    AudioTapBackend backend = const PluginTapBackend(),
    DateTime? now,
  }) async {
    if (!backend.supported) return null;
    final t = now ?? DateTime.now();
    final dir = Directory('$baseDir${Platform.pathSeparator}call-audio-${_stamp(t)}');
    await dir.create(recursive: true);
    final s = AudioDiagnosticsSession._(backend, dir.path, t, settings);
    await s._startSend(rtc.HubbubSendTap.processed, 'send-processed.wav');
    // The raw microphone is not reachable (a sink on the local track delivers the processed
    // signal, measured); the closest tap is the signal as Hubbub's hook receives it, after the
    // audio engine's echo cancellation, noise suppression and gain control.
    await s._startSend(rtc.HubbubSendTap.input, 'send-hook-input.wav');
    return s;
  }

  String _path(String name) => '$directory${Platform.pathSeparator}$name';

  Future<void> _startSend(rtc.HubbubSendTap tap, String name) async {
    try {
      final ms = await _backend.startSend(tap, _path(name));
      _entries[name] = {'kind': tap.wire, 'tapStartMs': ms};
    } catch (e) {
      _entries[name] = {'kind': tap.wire, 'error': '$e'};
    }
  }

  /// The decoded audio of one remote person. Several tracks of one person get a number.
  Future<void> addRemote(String name, String trackId) async {
    if (_stopped || _trackFiles.containsKey(trackId)) return;
    var base = 'recv-${safeFileName(name)}';
    var file = '$base.wav';
    for (var i = 2; _usedNames.contains(file); i++) {
      file = '$base-$i.wav';
    }
    _usedNames.add(file);
    _trackFiles[trackId] = file;
    try {
      final ms = await _backend.startTrack(trackId, _path(file));
      _entries[file] = {'kind': 'remote', 'participant': name, 'tapStartMs': ms};
    } catch (e) {
      _entries[file] = {'kind': 'remote', 'participant': name, 'error': '$e'};
    }
  }

  /// Finishes one remote file early (the person left); the file stays in the report.
  Future<void> removeTrack(String trackId) async {
    final file = _trackFiles.remove(trackId);
    if (file == null) return;
    try {
      _fold(file, await _backend.stopTrack(trackId));
    } catch (e) {
      _entries[file]?['error'] = '$e';
    }
  }

  void _fold(String file, rtc.HubbubTapResult? r) {
    if (r == null) return;
    _entries[file] = {...?_entries[file], ...r.toJson()}..remove('path');
  }

  /// Stops every tap, writes `session.json` and reports the folder.
  Future<AudioDiagnosticsReport> stop() async {
    if (!_stopped) {
      _stopped = true;
      for (final tap in rtc.HubbubSendTap.values) {
        final name = tap == rtc.HubbubSendTap.processed ? 'send-processed.wav' : 'send-hook-input.wav';
        try {
          _fold(name, await _backend.stopSend(tap));
        } catch (e) {
          _entries[name]?['error'] = '$e';
        }
      }
      for (final id in _trackFiles.keys.toList()) {
        await removeTrack(id);
      }
      Map<dynamic, dynamic>? native;
      try {
        native = await _backend.status();
      } catch (_) {}
      final doc = {
        'format': 1,
        'startedAtMs': started.millisecondsSinceEpoch,
        'startedAtIso': started.toUtc().toIso8601String(),
        'endedAtMs': DateTime.now().millisecondsSinceEpoch,
        'note': 'All WAV files are mono 16-bit 48 kHz. Times are wall clock ms since the epoch '
            '(this PC); align files of one PC with tapStartMs/firstSampleMs, files from two PCs '
            'by cross-correlation (tools/audio_compare.py).',
        'settings': _settings,
        if (native != null) 'captureHook': {for (final e in native.entries) '${e.key}': e.value},
        'files': _entries,
      };
      await File(_path('session.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
    }
    final names = _entries.keys.toList()..sort();
    return AudioDiagnosticsReport(directory: directory, files: [...names, 'session.json']);
  }
}

/// Opens [directory] in the system file manager.
Future<void> openFolder(String directory) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', [directory]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [directory]);
  } else {
    await Process.run('xdg-open', [directory]);
  }
}
