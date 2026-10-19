import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// How the microphone is captured, in one place for connect, the live input restart and the
/// mic toggle.
///
/// Linux drops automatic gain: the libwebrtc analog AGC cannot change the OS mic level (the
/// audio transport ignores the volume it is given), but its digital gain and limiter still
/// amplify a mic that already clips at the source, which is heard as a buzz on the far side.
/// Echo cancellation and noise suppression stay on everywhere.
AudioCaptureOptions captureOptionsFor(String? deviceId, {TargetPlatform? platform}) =>
    AudioCaptureOptions(
      deviceId: deviceId,
      noiseSuppression: true,
      echoCancellation: true,
      autoGainControl: (platform ?? defaultTargetPlatform) != TargetPlatform.linux,
    );
