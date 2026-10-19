import 'package:livekit_client/livekit_client.dart';

/// Camera: 960x540 at 30 fps, up to 1 Mbps, with one 360p15 simulcast layer that the grid
/// tiles subscribe to. Degradation is balanced, so under pressure cameras step down before
/// the screen share (which keeps its resolution) and long before voice.
CameraCaptureOptions cameraCaptureOptionsFor(String? deviceId) => CameraCaptureOptions(
      deviceId: deviceId,
      maxFrameRate: 30,
      params: const VideoParameters(
        dimensions: VideoDimensions(960, 540),
        encoding: VideoEncoding(maxFramerate: 30, maxBitrate: 1000000),
      ),
    );

const cameraPublishOptions = VideoPublishOptions(
  name: VideoPublishOptions.defaultCameraName,
  videoEncoding: VideoEncoding(maxFramerate: 30, maxBitrate: 1000000),
  simulcast: true,
  videoSimulcastLayers: [
    VideoParameters(
      dimensions: VideoDimensions(640, 360),
      encoding: VideoEncoding(maxFramerate: 15, maxBitrate: 300000),
    ),
  ],
  backupVideoCodec: BackupVideoCodec(enabled: false),
  degradationPreference: DegradationPreference.balanced,
);
