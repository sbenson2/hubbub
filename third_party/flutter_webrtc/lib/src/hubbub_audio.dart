// Hubbub patch: Dart side of the capture post-processor (RNNoise, input gain,
// peak meter). Native side: common/cpp/src/hubbub_audio.cc, windows/linux plugin.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native/event_channel.dart';
import 'native/utils.dart';

/// What the microphone does between the audio device and the encoder.
enum HubbubNoiseSuppression {
  /// Nothing beyond echo cancellation.
  off,

  /// The WebRTC noise suppressor, chosen with the `noiseSuppression` capture constraint.
  webrtc,

  /// RNNoise in the capture post-processor. Capture with `noiseSuppression: false`.
  rnnoise,
}

/// Peaks over the last ~50 ms of microphone audio; published about 20 times a second.
@immutable
class HubbubLevels {
  const HubbubLevels({
    required this.pre,
    required this.post,
    this.speech = -1,
    this.clip = 0,
  });

  /// Peak (0 to 1) before RNNoise and input gain: what the device and echo canceller delivered.
  final double pre;

  /// Peak (0 to 1) after input gain and the limiter: what is sent.
  final double post;

  /// RNNoise speech probability 0 to 1, or -1 when RNNoise is off.
  final double speech;

  /// Share (0 to 1) of 10 ms blocks in the window whose [pre] peak was at least 0.98.
  final double clip;

  static HubbubLevels? fromEvent(Object? e) {
    if (e is! Map) return null;
    double d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
    return HubbubLevels(
      pre: d(e['pre'], 0).clamp(0.0, 1.0),
      post: d(e['post'], 0).clamp(0.0, 1.0),
      speech: d(e['speech'], -1),
      clip: d(e['clip'], 0).clamp(0.0, 1.0),
    );
  }

  @override
  String toString() => 'pre=$pre post=$post clip=$clip speech=$speech';
}

/// Controls the native capture post-processor. Only Windows and Linux have it.
class HubbubAudio {
  HubbubAudio._();

  static bool get supported => WebRTC.platformIsWindows || WebRTC.platformIsLinux;

  /// Turns RNNoise on for [HubbubNoiseSuppression.rnnoise], off otherwise.
  static Future<void> setNoiseSuppression(HubbubNoiseSuppression mode) =>
      WebRTC.invokeMethod('hubbubSetNoiseSuppression', <String, dynamic>{'mode': mode.name});

  /// Test-only: `classic` restores upstream RNNoise gain smoothing (no floor, no hold) so a test can
  /// compare it with the default. Normal use never calls this. [floorDb] is clamped to -25..-15 and
  /// [holdMs] to 150..250 natively.
  static Future<void> setTailMode({required bool classic, double floorDb = -20, double holdMs = 200}) =>
      WebRTC.invokeMethod('hubbubSetTailMode', <String, dynamic>{
        'mode': classic ? 'classic' : 'hold',
        'floorDb': floorDb,
        'holdMs': holdMs,
      });

  /// Input gain as a factor, 0 to 2 (0 to 200 percent), applied after RNNoise with a soft limiter.
  static Future<void> setInputGain(double gain) => WebRTC.invokeMethod(
      'hubbubSetInputGain', <String, dynamic>{'gain': gain.clamp(0.0, 2.0)});

  /// Calls seen by the processor and the audio layout it was given, for the app's log.
  static Future<Map<dynamic, dynamic>?> status() =>
      WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>('hubbubGetStatus');

  /// One line describing the audio layout the processor was given (rate, channels, bands,
  /// frames) and how many blocks it processed or had to skip. Sent when the layout changes and
  /// every 5 seconds, so the app can log what the real capture path looks like.
  static Stream<String> get layout => FlutterWebRTCEventChannel.instance.handleEvents.stream
      .where((e) => e.containsKey('hubbubLayout'))
      .map((e) {
        final m = e['hubbubLayout'];
        return m is Map && m['text'] is String ? m['text'] as String : null;
      })
      .where((t) => t != null)
      .cast<String>();

  /// Peak levels while the microphone is capturing.
  static Stream<HubbubLevels> get levels => FlutterWebRTCEventChannel.instance.handleEvents.stream
      .where((e) => e.containsKey('hubbubLevels'))
      .map((e) => HubbubLevels.fromEvent(e['hubbubLevels']))
      .where((l) => l != null)
      .cast<HubbubLevels>();
}

/// Camera settings of the native capture. Only Windows has them.
class HubbubCamera {
  HubbubCamera._();

  static bool get supported => WebRTC.platformIsWindows;

  /// Whether the next camera capture may switch the webcam's auto-exposure priority off, so
  /// it does not drop to half the frame rate in dim light. The native side restores the camera's
  /// own value when the capture stops. Takes effect at the next camera start.
  static Future<void> setLowLightFullFrameRate(bool on) =>
      WebRTC.invokeMethod('hubbubSetLowLightFullFrameRate', <String, dynamic>{'on': on});

  /// Gives every webcam its own auto-exposure priority back at once. For the app's quit, which
  /// ends with `exit()` and so runs no native destructors.
  static Future<void> restoreExposure() => WebRTC.invokeMethod('hubbubRestoreCameraExposure');
}

/// What a diagnostic tap wrote (see [HubbubTaps]).
@immutable
class HubbubTapResult {
  const HubbubTapResult({
    required this.path,
    required this.startMs,
    required this.firstSampleMs,
    this.lastSampleMs = 0,
    this.maxGapMs = 0,
    this.gapsOver50Ms = 0,
    required this.samples,
    required this.droppedChunks,
    required this.capped,
    required this.sourceRate,
    this.sinkCalls = -1,
  });

  final String path;

  /// Wall clock (ms since the epoch) when the tap was started.
  final int startMs;

  /// Wall clock of the first audio block (0 when none arrived).
  final int firstSampleMs;

  /// Wall clock of the last audio block. (lastSampleMs - firstSampleMs) against [seconds] shows
  /// whether the audio arrived faster or slower than real time.
  final int lastSampleMs;

  /// Longest wait between two audio blocks (ms), and how many waits were over 50 ms. A healthy
  /// 10 ms capture or playout clock stays below about 30 ms.
  final int maxGapMs;
  final int gapsOver50Ms;

  /// 48 kHz samples in the file.
  final int samples;

  /// Blocks lost because the writer fell behind (should be 0).
  final int droppedChunks;

  /// The 10 minute cap was reached.
  final bool capped;

  /// Sample rate the audio had before it was resampled to 48 kHz.
  final int sourceRate;

  /// For track recordings: how often the sink was called (-1 for the send taps).
  final int sinkCalls;

  double get seconds => samples / 48000.0;

  static HubbubTapResult? fromMap(Object? m) {
    if (m is! Map) return null;
    int i(Object? v) => v is num ? v.toInt() : 0;
    return HubbubTapResult(
      path: m['path'] is String ? m['path'] as String : '',
      startMs: i(m['startMs']),
      firstSampleMs: i(m['firstSampleMs']),
      lastSampleMs: i(m['lastSampleMs']),
      maxGapMs: i(m['maxGapMs']),
      gapsOver50Ms: i(m['gapsOver50Ms']),
      samples: i(m['samples']),
      droppedChunks: i(m['droppedChunks']),
      capped: m['capped'] == true,
      sourceRate: i(m['sourceRate']),
      sinkCalls: m['sinkCalls'] is num ? i(m['sinkCalls']) : -1,
    );
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'startMs': startMs,
        'firstSampleMs': firstSampleMs,
        'lastSampleMs': lastSampleMs,
        'maxGapMs': maxGapMs,
        'gapsOver50Ms': gapsOver50Ms,
        'samples': samples,
        'seconds': seconds,
        'droppedChunks': droppedChunks,
        'capped': capped,
        'sourceRate': sourceRate,
        if (sinkCalls >= 0) 'sinkCalls': sinkCalls,
      };
}

/// Which send-side signal a tap records.
enum HubbubSendTap {
  /// The capture signal as Hubbub's hook receives it: after the audio engine's echo
  /// cancellation, noise suppression and gain control (and after an injected file).
  input('sendInput'),

  /// The signal leaving the hook, after RNNoise, input gain and the limiter. This is
  /// what the Opus encoder gets (the engine resamples it to 48 kHz after the hook).
  processed('sendProcessed');

  const HubbubSendTap(this.wire);
  final String wire;
}

/// Diagnostic audio taps (measurement only, off unless started). Each writes a mono 48 kHz WAV,
/// capped at 10 minutes, on a background thread. Windows and Linux only.
class HubbubTaps {
  HubbubTaps._();

  static bool get supported => HubbubAudio.supported;

  /// Starts recording a send-side tap to [path]. Returns the wall clock start (ms since epoch).
  static Future<int> start(HubbubSendTap tap, String path, {double? maxSeconds}) async {
    final r = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>('hubbubTapStart', <String, dynamic>{
      'kind': tap.wire,
      'path': path,
      if (maxSeconds != null) 'maxSeconds': maxSeconds,
    });
    final v = r?['startMs'];
    return v is num ? v.toInt() : 0;
  }

  static Future<HubbubTapResult?> stop(HubbubSendTap tap) async => HubbubTapResult.fromMap(
      await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
          'hubbubTapStop', <String, dynamic>{'kind': tap.wire}));

  /// Records the decoded audio of one track (a remote participant's, before the playout mix).
  /// Returns the wall clock start (ms since epoch).
  static Future<int> recordTrack(String trackId, String path) async {
    final r = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
        'hubbubRecordTrack', <String, dynamic>{'trackId': trackId, 'path': path});
    final v = r?['startMs'];
    return v is num ? v.toInt() : 0;
  }

  static Future<HubbubTapResult?> stopTrack(String trackId) async => HubbubTapResult.fromMap(
      await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
          'hubbubStopRecordTrack', <String, dynamic>{'trackId': trackId}));

  /// Fail-safe: stops both send taps, every track tap and the playout tap. Safe when nothing runs.
  static Future<void> stopAll() => WebRTC.invokeMethod('hubbubTapStopAll');

  /// Test only: replaces the capture signal at the hook with a WAV file. [injectLoad] makes the
  /// microphone silent until [injectPlay]; [injectStop] gives the microphone back.
  static Future<void> injectLoad(String path) => WebRTC.invokeMethod(
      'hubbubInject', <String, dynamic>{'action': 'load', 'path': path});

  /// Starts the injected file from its first sample. Returns the wall clock start (ms).
  static Future<int> injectPlay() async {
    final r = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
        'hubbubInject', <String, dynamic>{'action': 'play'});
    final v = r?['startMs'];
    return v is num ? v.toInt() : 0;
  }

  static Future<void> injectStop() =>
      WebRTC.invokeMethod('hubbubInject', <String, dynamic>{'action': 'stop'});

  /// The final playout mix of all remote audio, at the render hook. The first call registers the
  /// hook with the audio engine; before that a call does not touch the render path at all.
  static Future<int> playoutTapStart(String path) async {
    final r = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
        'hubbubPlayout', <String, dynamic>{'action': 'tapStart', 'path': path});
    final v = r?['startMs'];
    return v is num ? v.toInt() : 0;
  }

  static Future<HubbubTapResult?> playoutTapStop() async => HubbubTapResult.fromMap(
      await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
          'hubbubPlayout', <String, dynamic>{'action': 'tapStop'}));

  /// Test only: silences the playout (the remote tracks and the mix tap still get the audio).
  static Future<void> setPlayoutMuted(bool on) => WebRTC.invokeMethod(
      'hubbubPlayout', <String, dynamic>{'action': 'mute', 'on': on});

  /// `muted`, `tap`, `rate`, `channels`, `calls` of the render hook.
  static Future<Map<dynamic, dynamic>?> playoutStatus() =>
      WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
          'hubbubPlayout', <String, dynamic>{'action': 'status'});

  /// `sendProcessed`, `sendInput`, `injectActive`, `injectFinished`, `rate`.
  static Future<Map<dynamic, dynamic>?> status() =>
      WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>('hubbubTapStatus');
}
