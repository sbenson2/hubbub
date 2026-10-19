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

/// Screen share capture: 1080p at up to 60 fps, at most 6 Mbps for the top layer.
ScreenShareCaptureOptions screenCaptureOptionsFor(String? sourceId) => ScreenShareCaptureOptions(
      sourceId: sourceId,
      maxFrameRate: 60,
      params: const VideoParameters(
        dimensions: VideoDimensions(1920, 1080),
        encoding: VideoEncoding(maxFramerate: 60, maxBitrate: 6000000),
      ),
    );

/// Screen share publishing: the 1080p60 layer plus 720p30 and 360p15 for viewers who cannot
/// take it. The resolution is kept when bandwidth drops (text must stay readable), so it is
/// the frame rate that gives way. H.264 only and no backup codec: calls are end-to-end
/// encrypted and the frame cryptor skips AV1 (and the backup codec's sender gets none), which
/// would send the picture to the SFU in the clear. AV1 also forces SVC, which drops the layers.
VideoPublishOptions screenPublishOptionsFor() => const VideoPublishOptions(
      name: VideoPublishOptions.defaultScreenShareName,
      videoCodec: 'h264',
      backupVideoCodec: BackupVideoCodec(enabled: false),
      screenShareEncoding: VideoEncoding(maxFramerate: 60, maxBitrate: 6000000),
      simulcast: true,
      screenShareSimulcastLayers: [
        VideoParameters(
          dimensions: VideoDimensions(1280, 720),
          encoding: VideoEncoding(maxFramerate: 30, maxBitrate: 2500000),
        ),
        VideoParameters(
          dimensions: VideoDimensions(640, 360),
          encoding: VideoEncoding(maxFramerate: 15, maxBitrate: 600000),
        ),
      ],
      degradationPreference: DegradationPreference.maintainResolution,
    );

/// Codecs for which livekit_client 2.13.1 sets up no frame cryptor, on the sender
/// (`e2ee_manager.dart:51-54`) or the receiver (`:88-90`): published, they go unencrypted.
const frameCryptorSkipsCodecs = <String>{'av1'};
