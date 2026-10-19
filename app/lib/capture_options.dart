import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// Which noise suppressor cleans the microphone. Discord's Noise Suppression choices.
enum NoiseSuppression {
  /// Echo cancellation only.
  none('None'),

  /// The WebRTC noise suppressor (stationary noise only).
  standard('Standard'),

  /// RNNoise in the capture post-processor of the patched flutter_webrtc: better on keys, fans
  /// and background voices.
  rnnoise('Hubbub (RNNoise)');

  const NoiseSuppression(this.label);
  final String label;

  static NoiseSuppression fromName(Object? name) => NoiseSuppression.values
      .firstWhere((n) => n.name == name, orElse: () => NoiseSuppression.rnnoise);
}

/// RNNoise lives in the desktop plugin (Windows and Linux); elsewhere a request for it is
/// served by the standard suppressor so the mic is never left unfiltered by surprise.
NoiseSuppression effectiveNoiseSuppression(NoiseSuppression ns, {TargetPlatform? platform}) {
  final p = platform ?? defaultTargetPlatform;
  final desktop = p == TargetPlatform.windows || p == TargetPlatform.linux;
  return ns == NoiseSuppression.rnnoise && !desktop ? NoiseSuppression.standard : ns;
}

/// How the microphone is captured, in one place for connect, the live input restart and the
/// mic toggle.
///
/// The WebRTC noise suppressor is on only for [NoiseSuppression.standard]; with RNNoise the
/// two would work on top of each other. Echo cancellation stays on everywhere.
///
/// Linux drops automatic gain: the libwebrtc analog AGC cannot change the OS mic level (the
/// audio transport ignores the volume it is given), but its digital gain and limiter still
/// amplify a mic that already clips at the source, which is heard as a buzz on the far side.
AudioCaptureOptions captureOptionsFor(String? deviceId,
    {TargetPlatform? platform, NoiseSuppression noiseSuppression = NoiseSuppression.rnnoise}) {
  final p = platform ?? defaultTargetPlatform;
  return AudioCaptureOptions(
    deviceId: deviceId,
    noiseSuppression: effectiveNoiseSuppression(noiseSuppression, platform: p) ==
        NoiseSuppression.standard,
    echoCancellation: true,
    autoGainControl: p != TargetPlatform.linux,
  );
}
