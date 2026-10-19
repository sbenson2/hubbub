import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/capture_options.dart';

void main() {
  group('capture options', () {
    test('linux_turns_automatic_gain_off_and_keeps_echo_and_noise_processing', () {
      final o = captureOptionsFor('m1', platform: TargetPlatform.linux);
      expect(o.autoGainControl, isFalse);
      expect(o.echoCancellation, isTrue);
      expect(o.noiseSuppression, isTrue);
      expect(o.deviceId, 'm1');
    });

    for (final p in [TargetPlatform.windows, TargetPlatform.macOS]) {
      test('${p.name}_keeps_all_three_on', () {
        final o = captureOptionsFor(null, platform: p);
        expect(o.autoGainControl, isTrue);
        expect(o.echoCancellation, isTrue);
        expect(o.noiseSuppression, isTrue);
        expect(o.deviceId, isNull);
      });
    }
  });
}
