import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/video_options.dart';
import 'package:livekit_client/livekit_client.dart';

void main() {
  group('camera options', () {
    test('capture_is_960x540_at_30_on_the_chosen_device', () {
      final o = cameraCaptureOptionsFor('cam1');
      expect(o.deviceId, 'cam1');
      expect(o.params.dimensions.width, 960);
      expect(o.params.dimensions.height, 540);
      expect(o.maxFrameRate, 30);
      expect(o.params.encoding?.maxFramerate, 30);
      expect(o.params.encoding?.maxBitrate, 1000000);
      expect(cameraCaptureOptionsFor(null).deviceId, isNull);
    });

    test('publish_has_a_360p15_simulcast_layer_and_balanced_degradation', () {
      expect(cameraPublishOptions.simulcast, isTrue);
      expect(cameraPublishOptions.videoEncoding?.maxBitrate, 1000000);
      expect(cameraPublishOptions.videoEncoding?.maxFramerate, 30);
      final layer = cameraPublishOptions.videoSimulcastLayers.single;
      expect(layer.dimensions.width, 640);
      expect(layer.dimensions.height, 360);
      expect(layer.encoding?.maxFramerate, 15);
      expect(cameraPublishOptions.degradationPreference, DegradationPreference.balanced);
    });
  });
}
