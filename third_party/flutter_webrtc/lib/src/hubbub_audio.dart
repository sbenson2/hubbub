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
}
