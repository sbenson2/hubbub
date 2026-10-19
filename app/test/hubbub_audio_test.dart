import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/capture_options.dart';
import 'package:hubbub/room_adapter.dart';

/// The patched flutter_webrtc plugin's method channel, with a fake native side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  // The plugin listens to its event channel once per process, so the fake native side has to be
  // there before the first call touches it.
  MockStreamHandlerEventSink? eventSink;
  const events = EventChannel('FlutterWebRTC.Event');
  setUpAll(() => messenger.setMockStreamHandler(
      events, MockStreamHandler.inline(onListen: (args, sink) => eventSink = sink)));

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), null);
  });

  final desktop = Platform.isWindows || Platform.isLinux;

  String show(MethodCall c) => '${c.method} ${c.arguments}';
  List<MethodCall> hubbub() => calls.where((c) => c.method.startsWith('hubbub')).toList();

  group('hubbub audio channel', () {
    test('input_gain_goes_to_the_plugin_as_a_factor_between_0_and_2', () async {
      await rtc.HubbubAudio.setInputGain(0.5);
      await rtc.HubbubAudio.setInputGain(7);
      expect(hubbub().map(show), ['hubbubSetInputGain {gain: 0.5}', 'hubbubSetInputGain {gain: 2.0}']);
    });

    test('noise_suppression_modes_are_sent_by_name', () async {
      for (final m in rtc.HubbubNoiseSuppression.values) {
        await rtc.HubbubAudio.setNoiseSuppression(m);
      }
      expect(hubbub().map((c) => (c.arguments as Map)['mode']), ['off', 'webrtc', 'rnnoise']);
    });

    test('level_events_decode_to_peaks_and_junk_is_dropped', () async {
      final got = <rtc.HubbubLevels>[];
      final sub = rtc.HubbubAudio.levels.listen(got.add);
      addTearDown(sub.cancel);
      for (var i = 0; i < 50 && eventSink == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final sink = eventSink!;
      sink.success(<String, Object?>{'event': 'onDeviceChange'});
      sink.success(<String, Object?>{
        'event': 'hubbubLevels',
        'pre': 0.5,
        'post': 1.5,
        'speech': 0.75,
        'clip': 0.2
      });
      sink.success(<String, Object?>{'event': 'hubbubLevels'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got.length, 2, reason: 'the device-change event is not a level');
      expect((got[0].pre, got[0].post, got[0].speech, got[0].clip), (0.5, 1.0, 0.75, 0.2));
      expect((got[1].pre, got[1].post, got[1].speech, got[1].clip), (0.0, 0.0, -1.0, 0.0));
    });

    test('layout_events_decode_to_a_log_line_and_junk_is_dropped', () async {
      final got = <String>[];
      final sub = rtc.HubbubAudio.layout.listen(got.add);
      addTearDown(sub.cancel);
      for (var i = 0; i < 50 && eventSink == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final sink = eventSink!;
      sink.success(<String, Object?>{'event': 'hubbubLevels', 'pre': 0.5});
      sink.success(<String, Object?>{
        'event': 'hubbubLayout',
        'text': 'rate=48000 ch=1 bands=3 frames=480 size=480 processed=10 skipped=0'
      });
      sink.success(<String, Object?>{'event': 'hubbubLayout', 'text': 7});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, ['rate=48000 ch=1 bands=3 frames=480 size=480 processed=10 skipped=0']);
    });
  });

  group('adapter', () {
    test('the_input_volume_and_suppressor_reach_the_plugin_out_of_a_call', () async {
      debugDefaultTargetPlatformOverride = Platform.isLinux ? TargetPlatform.linux : TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final adapter = LiveKitRoomAdapter();
      addTearDown(adapter.dispose);
      await adapter.setInputGain(0.25);
      await adapter.setNoiseSuppression(NoiseSuppression.rnnoise);
      await adapter.setNoiseSuppression(NoiseSuppression.standard);
      expect(hubbub().map(show), [
        'hubbubSetInputGain {gain: 0.25}',
        'hubbubSetNoiseSuppression {mode: rnnoise}',
        'hubbubSetNoiseSuppression {mode: webrtc}',
      ]);
    }, skip: desktop ? false : 'the plugin only exists on Windows and Linux');
  });
}
