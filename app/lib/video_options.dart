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
/// the frame rate that gives way. AV1 is preferred with an H.264 backup for viewers that
/// cannot decode it; without AV1 on this machine the share is plain H.264.
VideoPublishOptions screenPublishOptionsFor({required bool av1}) => VideoPublishOptions(
      name: VideoPublishOptions.defaultScreenShareName,
      videoCodec: av1 ? 'av1' : 'h264',
      backupVideoCodec: av1 ? const BackupVideoCodec(codec: 'h264') : const BackupVideoCodec(enabled: false),
      screenShareEncoding: const VideoEncoding(maxFramerate: 60, maxBitrate: 6000000),
      simulcast: true,
      screenShareSimulcastLayers: const [
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

/// Whether the platform's video sender lists AV1 (mime types from `getRtpSenderCapabilities`).
bool canSendAv1(Iterable<String> mimeTypes) => mimeTypes.any((m) => m.toLowerCase() == 'video/av1');
