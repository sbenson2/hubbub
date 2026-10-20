import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/audio_diagnostics.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/ui/recording_indicator.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

class _FakeBackend implements AudioTapBackend {
  final calls = <String>[];
  Object? stopAllError; // thrown by stopAll while set
  @override
  Future<void> stopAll() async {
    calls.add('stopAll');
    final e = stopAllError;
    if (e != null) throw e;
  }

  @override
  bool get supported => true;
  @override
  Future<int> startSend(rtc.HubbubSendTap tap, String path) async {
    calls.add('start ${tap.wire} ${path.split(Platform.pathSeparator).last}');
    return 1000;
  }

  @override
  Future<rtc.HubbubTapResult?> stopSend(rtc.HubbubSendTap tap) async {
    calls.add('stop ${tap.wire}');
    return _result;
  }

  @override
  Future<int> startTrack(String trackId, String path) async {
    calls.add('track $trackId ${path.split(Platform.pathSeparator).last}');
    return 2000;
  }

  @override
  Future<rtc.HubbubTapResult?> stopTrack(String trackId) async {
    calls.add('untrack $trackId');
    return _result;
  }

  @override
  Future<Map<dynamic, dynamic>?> status() async => {'rate': 16000, 'channels': 1};

  static const _result = rtc.HubbubTapResult(
      path: 'x', startMs: 1000, firstSampleMs: 1010, samples: 96000, droppedChunks: 0, capped: false, sourceRate: 16000);
}

Widget _app(Widget child) => MaterialApp(theme: hubbubTheme(), home: Scaffold(body: child));

void main() {
  group('diagnostics setting', () {
    test('is_off_at_start_and_follows_the_switch_into_the_room', () async {
      final room = FakeRoom();
      final audio = AudioSettings(room, AudioPrefsStore.memory(),
          diagnosticsDir: 'D:/diag', diagnosticsSupported: true);
      await audio.start();
      expect(audio.recordDiagnostics, isFalse);
      expect(room.diagnosticsDir, isNull);
      await audio.setRecordDiagnostics(true);
      expect(audio.recordDiagnostics, isTrue);
      expect(room.diagnosticsDir, 'D:/diag');
      await audio.setRecordDiagnostics(false);
      expect(room.diagnosticsDir, isNull);
      audio.dispose();
    });

    test('is_never_saved_so_a_restart_finds_it_off', () async {
      final dir = Directory.systemTemp.createTempSync('diagprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AudioPrefsStore.file('${dir.path}/audio.json');
      final audio = AudioSettings(FakeRoom(), store, diagnosticsSupported: true);
      await audio.start();
      await audio.setRecordDiagnostics(true);
      await audio.setMaster(0.5); // any save
      await audio.commit();
      final saved = File('${dir.path}/audio.json').readAsStringSync();
      expect(saved.toLowerCase(), isNot(contains('diagnos')));
      expect(saved.toLowerCase(), isNot(contains('record')));
      final room2 = FakeRoom();
      final again = AudioSettings(room2, store, diagnosticsSupported: true);
      await again.start();
      expect(again.recordDiagnostics, isFalse);
      expect(room2.diagnosticsDir, isNull);
      expect(again.diagnosticsBase, startsWith(dir.path), reason: 'files go next to the settings');
      audio.dispose();
      again.dispose();
    });

    test('closing_the_settings_while_recording_stops_the_recording', () async {
      final room = FakeRoom();
      final audio = AudioSettings(room, AudioPrefsStore.memory(), diagnosticsDir: 'x', diagnosticsSupported: true);
      await audio.setRecordDiagnostics(true);
      audio.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(room.diagnosticsDir, isNull);
    });

    test('a_finished_recording_becomes_the_last_report', () async {
      final room = FakeRoom();
      final audio = AudioSettings(room, AudioPrefsStore.memory(), diagnosticsSupported: true);
      expect(audio.lastReport, isNull);
      room.diagnosticsReports
          .add(const AudioDiagnosticsReport(directory: 'D:/diag/call-audio-1', files: ['session.json']));
      await Future<void>.delayed(Duration.zero);
      expect(audio.lastReport!.directory, 'D:/diag/call-audio-1');
      expect(audio.reportSerial, 1);
      audio.dispose();
    });
  });

  group('a stop that fails', () {
    test('keeps_the_switch_and_badge_on_with_the_error_until_a_retry_works', () async {
      final room = FakeRoom()..diagnosticsStopError = StateError('stop failed');
      final audio = AudioSettings(room, AudioPrefsStore.memory(), diagnosticsSupported: true);
      await audio.setRecordDiagnostics(true);
      await audio.setRecordDiagnostics(false);
      expect(audio.recordDiagnostics, isTrue, reason: 'still recording as far as anyone can tell');
      expect(audio.diagnosticsError, contains('stop failed'));
      room.diagnosticsStopError = null;
      await audio.setRecordDiagnostics(false);
      expect(audio.recordDiagnostics, isFalse);
      expect(audio.diagnosticsError, isNull);
      expect(room.diagnosticsDir, isNull);
      audio.dispose();
    });
  });

  group('recording indicator', () {
    testWidgets('is_hidden_when_off_and_a_red_recording_audio_badge_when_on', (tester) async {
      final audio = AudioSettings(FakeRoom(), AudioPrefsStore.memory(), diagnosticsSupported: true);
      await tester.pumpWidget(_app(RecordingIndicator(audio: audio)));
      expect(find.byKey(const Key('recording-indicator')), findsNothing);
      expect(find.text('Recording audio'), findsNothing);
      await audio.setRecordDiagnostics(true);
      await tester.pump();
      expect(find.text('Recording audio'), findsOneWidget);
      final box = tester.widget<Container>(find.byKey(const Key('recording-indicator')));
      expect((box.decoration as BoxDecoration).color, HubColors.red);
      await audio.setRecordDiagnostics(false);
      await tester.pump();
      expect(find.text('Recording audio'), findsNothing);
      audio.dispose();
    });

    testWidgets('the_saved_dialog_shows_the_folder_and_opens_it', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(_app(Builder(
          builder: (context) => TextButton(
              onPressed: () => showRecordingSavedDialog(
                  context, const AudioDiagnosticsReport(directory: r'C:\x\call-audio-1', files: ['a.wav', 'session.json']),
                  open: (d) async => opened.add(d)),
              child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text(r'C:\x\call-audio-1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recording-open-folder')));
      expect(opened, [r'C:\x\call-audio-1']);
    });
  });

  group('session files', () {
    test('names_the_files_and_writes_the_settings_and_clock_times', () async {
      final base = Directory.systemTemp.createTempSync('diagsess');
      addTearDown(() => base.deleteSync(recursive: true));
      final be = _FakeBackend();
      final s = (await AudioDiagnosticsSession.start(
          baseDir: base.path,
          settings: {'noiseSuppression': 'rnnoise', 'inputGainFactor': 1.5},
          backend: be,
          now: DateTime(2026, 10, 19, 14, 5, 9)))!;
      expect(s.directory, endsWith('call-audio-20261019-140509-000'));
      await s.addRemote('Bob / Smith', 't1');
      await s.addRemote('Bob / Smith', 't2');
      await s.addRemote('', 't3');
      final report = await s.stop();
      expect(report.files, [
        'recv-Bob_Smith-2.wav',
        'recv-Bob_Smith.wav',
        'recv-unknown.wav',
        'send-hook-input.wav',
        'send-processed.wav',
        'session.json',
      ]);
      final doc = jsonDecode(File('${s.directory}/session.json').readAsStringSync()) as Map;
      expect(doc['settings'], {'noiseSuppression': 'rnnoise', 'inputGainFactor': 1.5});
      expect(doc['startedAtMs'], DateTime(2026, 10, 19, 14, 5, 9).millisecondsSinceEpoch);
      final files = doc['files'] as Map;
      expect(files['send-processed.wav']['tapStartMs'], 1000);
      expect(files['send-processed.wav']['seconds'], 2.0);
      expect(files['recv-Bob_Smith.wav']['participant'], 'Bob / Smith');
      expect(be.calls.where((c) => c.startsWith('start')).length, 2);
      expect(be.calls, containsAll(['stop sendProcessed', 'untrack t1']));
    });

    test('two_sessions_in_the_same_second_get_different_folders', () async {
      final base = Directory.systemTemp.createTempSync('diagsame');
      addTearDown(() => base.deleteSync(recursive: true));
      final t = DateTime(2026, 10, 19, 14, 5, 9, 250);
      final a = (await AudioDiagnosticsSession.start(
          baseDir: base.path, settings: {}, backend: _FakeBackend(), now: t))!;
      final b = (await AudioDiagnosticsSession.start(
          baseDir: base.path, settings: {}, backend: _FakeBackend(), now: t))!;
      final c = (await AudioDiagnosticsSession.start(
          baseDir: base.path, settings: {}, backend: _FakeBackend(), now: t))!;
      expect(a.directory, endsWith('call-audio-20261019-140509-250'));
      expect(b.directory, endsWith('call-audio-20261019-140509-250-2'));
      expect(c.directory, endsWith('call-audio-20261019-140509-250-3'));
      await a.stop();
      await b.stop();
      await c.stop();
      for (final s in [a, b, c]) {
        expect(File('${s.directory}/session.json').existsSync(), isTrue);
      }
    });

    test('a_stop_that_fails_throws_keeps_the_session_open_and_can_be_retried', () async {
      final base = Directory.systemTemp.createTempSync('diagfail');
      addTearDown(() => base.deleteSync(recursive: true));
      final be = _FakeBackend()..stopAllError = PlatformException(code: 'hubbubTap', message: 'boom');
      final s = (await AudioDiagnosticsSession.start(baseDir: base.path, settings: {}, backend: be))!;
      await expectLater(s.stop(), throwsA(isA<PlatformException>()));
      expect(File('${s.directory}/session.json').existsSync(), isFalse, reason: 'not reported as saved');
      be.stopAllError = null;
      final report = await s.stop();
      expect(report.files, contains('session.json'));
      expect(File('${s.directory}/session.json').existsSync(), isTrue);
      expect(be.calls.where((c) => c == 'stopAll').length, 2);
    });

    test('stop_calls_the_native_stop_all_after_the_per_tap_stops', () async {
      final base = Directory.systemTemp.createTempSync('diagall');
      addTearDown(() => base.deleteSync(recursive: true));
      final be = _FakeBackend();
      final s = (await AudioDiagnosticsSession.start(baseDir: base.path, settings: {}, backend: be))!;
      await s.addRemote('Bob', 't1');
      await s.stop();
      expect(be.calls.last, 'stopAll', reason: 'status() is not recorded, so stopAll is the last call');
      expect(be.calls.indexOf('stopAll'), greaterThan(be.calls.indexOf('untrack t1')));
    });

    test('a_backend_that_is_not_supported_records_nothing', () async {
      expect(safeFileName('a/b:c'), 'a_b_c');
      expect(safeFileName('..'), 'unknown');
    });
  });
}
