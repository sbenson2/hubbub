import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/capture_options.dart';

void main() {
  group('capture options', () {
    test('linux_turns_automatic_gain_off_and_keeps_echo_cancellation', () {
      final o = captureOptionsFor('m1', platform: TargetPlatform.linux);
      expect(o.autoGainControl, isFalse);
      expect(o.echoCancellation, isTrue);
      expect(o.deviceId, 'm1');
    });

    for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
      test('${p.name}_with_rnnoise_turns_the_webrtc_suppressor_off_and_keeps_echo_cancellation', () {
        final o = captureOptionsFor(null, platform: p, noiseSuppression: NoiseSuppression.rnnoise);
        expect(o.noiseSuppression, isFalse);
        expect(o.echoCancellation, isTrue);
      });
      test('${p.name}_defaults_to_rnnoise', () {
        expect(captureOptionsFor(null, platform: p).noiseSuppression, isFalse);
      });
      test('${p.name}_standard_turns_the_webrtc_suppressor_on', () {
        final o = captureOptionsFor(null, platform: p, noiseSuppression: NoiseSuppression.standard);
        expect(o.noiseSuppression, isTrue);
        expect(o.echoCancellation, isTrue);
      });
      test('${p.name}_none_leaves_only_echo_cancellation', () {
        final o = captureOptionsFor(null, platform: p, noiseSuppression: NoiseSuppression.none);
        expect(o.noiseSuppression, isFalse);
        expect(o.echoCancellation, isTrue);
      });
    }

    test('windows_and_macos_keep_automatic_gain_on', () {
      for (final p in [TargetPlatform.windows, TargetPlatform.macOS]) {
        expect(captureOptionsFor(null, platform: p).autoGainControl, isTrue);
      }
    });

    test('macos_has_no_rnnoise_so_a_request_for_it_uses_the_standard_suppressor', () {
      expect(effectiveNoiseSuppression(NoiseSuppression.rnnoise, platform: TargetPlatform.macOS),
          NoiseSuppression.standard);
      final o = captureOptionsFor(null, platform: TargetPlatform.macOS);
      expect(o.noiseSuppression, isTrue);
      expect(o.echoCancellation, isTrue);
    });

    test('saved_names_round_trip_and_unknown_ones_fall_back_to_rnnoise', () {
      for (final n in NoiseSuppression.values) {
        expect(NoiseSuppression.fromName(n.name), n);
      }
      expect(NoiseSuppression.fromName('krisp'), NoiseSuppression.rnnoise);
      expect(NoiseSuppression.fromName(null), NoiseSuppression.rnnoise);
    });
  });
}
