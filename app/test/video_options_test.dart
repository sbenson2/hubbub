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

  group('screen share options', () {
    test('capture_is_1080p_at_up_to_60_fps_from_the_picked_source', () {
      final o = screenCaptureOptionsFor('window:42:0');
      expect(o.deviceId, 'window:42:0');
      expect(o.params.dimensions.width, 1920);
      expect(o.params.dimensions.height, 1080);
      expect(o.maxFrameRate, 60);
      expect(o.params.encoding?.maxFramerate, 60);
      expect(o.params.encoding?.maxBitrate, 6000000);
    });

    test('publish_has_720p30_and_360p15_layers_and_keeps_its_resolution', () {
      final o = screenPublishOptionsFor();
      expect(o.screenShareEncoding?.maxFramerate, 60);
      expect(o.screenShareEncoding?.maxBitrate, 6000000);
      expect(o.simulcast, isTrue);
      final layers = o.screenShareSimulcastLayers;
      expect(layers.length, 2);
      expect((layers[0].dimensions.height, layers[0].encoding?.maxFramerate, layers[0].encoding?.maxBitrate),
          (720, 30, 2500000));
      expect((layers[1].dimensions.height, layers[1].encoding?.maxFramerate, layers[1].encoding?.maxBitrate),
          (360, 15, 600000));
      expect(o.degradationPreference, DegradationPreference.maintainResolution);
    });

    test('the_share_is_h264_only_with_no_backup_codec', () {
      // AV1 would skip the frame cryptor (livekit_client 2.13.1 e2ee_manager.dart:51-54, :88-90)
      // and a backup codec's sender gets none, so the share would reach the SFU unencrypted.
      final o = screenPublishOptionsFor();
      expect(o.videoCodec, 'h264');
      expect(o.backupVideoCodec.enabled, isFalse);
      expect(o.screenShareSimulcastLayers.length, 2);
    });

    test('every_published_video_codec_is_one_the_frame_cryptor_covers', () {
      for (final o in [cameraPublishOptions, screenPublishOptionsFor()]) {
        expect(frameCryptorSkipsCodecs, contains('av1'));
        expect(frameCryptorSkipsCodecs.contains(o.videoCodec.toLowerCase()), isFalse,
            reason: '${o.name}: ${o.videoCodec} would be sent unencrypted');
        if (o.backupVideoCodec.enabled) {
          expect(frameCryptorSkipsCodecs.contains(o.backupVideoCodec.codec.toLowerCase()), isFalse,
              reason: '${o.name}: backup ${o.backupVideoCodec.codec} would be sent unencrypted');
        }
      }
    });
  });
}
