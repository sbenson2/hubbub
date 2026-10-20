import 'package:livekit_client/livekit_client.dart';

/// Camera: 1280x720 at up to 60 fps (a webcam gives what it has, usually 30), up to 2.5 Mbps,
/// with one 360p30 simulcast layer that the grid tiles subscribe to. Asking for 720p lets
/// webcams like the C920 use their 30 fps mode; a 960x540 request lands on a 15 fps one.
/// Degradation keeps the frame rate, so a loaded encoder drops resolution before motion
/// turns to a slideshow.
CameraCaptureOptions cameraCaptureOptionsFor(String? deviceId) => CameraCaptureOptions(
      deviceId: deviceId,
      maxFrameRate: 60,
      params: const VideoParameters(
        dimensions: VideoDimensions(1280, 720),
        encoding: VideoEncoding(maxFramerate: 60, maxBitrate: 2500000),
      ),
    );

const cameraPublishOptions = VideoPublishOptions(
  name: VideoPublishOptions.defaultCameraName,
  videoEncoding: VideoEncoding(maxFramerate: 60, maxBitrate: 2500000),
  simulcast: true,
  videoSimulcastLayers: [
    VideoParameters(
      dimensions: VideoDimensions(640, 360),
      encoding: VideoEncoding(maxFramerate: 30, maxBitrate: 500000),
    ),
  ],
  backupVideoCodec: BackupVideoCodec(enabled: false),
  degradationPreference: DegradationPreference.maintainFramerate,
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

/// Screen share publishing: the 1080p60 layer plus 720p60 and 360p30 for viewers who cannot
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
          encoding: VideoEncoding(maxFramerate: 60, maxBitrate: 3500000),
        ),
        VideoParameters(
          dimensions: VideoDimensions(640, 360),
          encoding: VideoEncoding(maxFramerate: 30, maxBitrate: 800000),
        ),
      ],
      degradationPreference: DegradationPreference.maintainResolution,
    );

/// Codecs for which livekit_client 2.13.1 sets up no frame cryptor, on the sender
/// (`e2ee_manager.dart:51-54`) or the receiver (`:88-90`): published, they go unencrypted.
const frameCryptorSkipsCodecs = <String>{'av1'};

/// Whether the screen is captured through the system's share prompt (xdg-desktop-portal and
/// PipeWire): a Wayland session on Linux. It is libwebrtc's own rule for choosing PipeWire
/// (`XDG_SESSION_TYPE` is `wayland` and `WAYLAND_DISPLAY` is set), so the two cannot disagree.
bool portalScreenShare({required bool isLinux, required Map<String, String> env}) =>
    isLinux && env['XDG_SESSION_TYPE'] == 'wayland' && (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

/// Whether this session can capture a screen or window. Windows, macOS and X11 capture
/// directly; Wayland captures through the system prompt ([portalScreenShare]). A session
/// with only one of the two Wayland variables set is refused: libwebrtc would pick X11 there
/// and get a black picture.
bool screenShareSupported({required bool isLinux, required Map<String, String> env}) =>
    !isLinux ||
    portalScreenShare(isLinux: isLinux, env: env) ||
    !(env['XDG_SESSION_TYPE'] == 'wayland' || (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty);

/// Whether a share carries sound. On Windows it is the app's own audio (process loopback,
/// which leaves Hubbub out); on Linux it is the whole PulseAudio monitor, which includes the
/// call itself and would echo it back to the watchers, so a Linux share is picture only.
bool shareAudioSupported({required bool isLinux}) => !isLinux;

/// How much to shrink every screen share layer so the top one is at most 1920x1080 of the
/// real capture. LiveKit computes the layer scales from the 1080p constraint, not from the
/// frames, so on a 4K screen the "1080p" layer would go out at 3840x2160. 1 when the capture
/// already fits.
double captureDownscale(num width, num height) {
  if (width <= 0 || height <= 0) return 1;
  final s = [width / 1920, height / 1080, 1.0].reduce((a, b) => a > b ? a : b);
  return s;
}

/// [bases] (each layer's `scaleResolutionDownBy` as LiveKit published it, null meaning 1)
/// multiplied by [factor]. Always from the base, never from a value already scaled.
List<double> scaledLayers(List<double?> bases, double factor) => [for (final s in bases) (s ?? 1) * factor];

/// One simulcast layer of a share as [ShareFit] needs it: the sender's current encoding
/// (`scale`, `active`) joined with the layer's last reported frame size.
class FitLayer {
  const FitLayer({this.rid, this.scale, this.active = true, this.frameWidth, this.frameHeight});

  final String? rid;

  /// The encoding's `scaleResolutionDownBy` right now (null means 1).
  final double? scale;

  /// False while the layer is paused (dynacast, or no viewer).
  final bool active;

  /// The last encoded frame size of this layer, null while it has produced none.
  final int? frameWidth;
  final int? frameHeight;

  /// The key a layer is filed under in a plan: its rid, `''` for a single unnamed layer.
  String get key => rid ?? '';
}

/// Scales one published screen share's layers down by the real capture size
/// ([captureDownscale]), once. Idempotent by construction: the layers' scales as LiveKit
/// published them are recorded the first time they are seen, the capture size comes from any
/// active layer's frame times that layer's scale, and each layer is set to its base times the
/// factor, never to its current value times it. After the plan has been written
/// ([markApplied]) it plans nothing more, so a stale frame size cannot scale twice.
class ShareFit {
  final _base = <String, double>{};
  int? _capW, _capH;

  /// Whether the layers already fit (written, or small enough to need nothing).
  bool applied = false;

  /// Writes that came back refused, so a build that never accepts them stops being retried.
  int failures = 0;

  /// Gives up retrying after this many refused writes.
  static const maxFailures = 5;

  bool get done => applied || failures >= maxFailures;

  /// The absolute `scaleResolutionDownBy` per [FitLayer.key] to write, or null when there is
  /// nothing to write now (already applied, no layer has produced a frame yet, or the capture
  /// fits).
  Map<String, double>? plan(List<FitLayer> layers) {
    if (done || layers.isEmpty) return null;
    for (final l in layers) {
      _base.putIfAbsent(l.key, () => l.scale ?? 1);
    }
    var capW = _capW, capH = _capH;
    if (capW == null || capH == null) {
      var area = 0;
      for (final l in layers) {
        final w = l.frameWidth, h = l.frameHeight;
        if (!l.active || w == null || h == null || w <= 0 || h <= 0 || w * h <= area) continue;
        area = w * h;
        final s = l.scale ?? 1;
        capW = (w * s).round();
        capH = (h * s).round();
      }
      if (capW == null || capH == null) return null;
      // Kept: once known, a refused write that left the cached scales changed cannot skew it.
      _capW = capW;
      _capH = capH;
    }
    final factor = captureDownscale(capW, capH);
    if (factor <= 1.001) {
      applied = true;
      return null;
    }
    return {for (final l in layers) l.key: scaledLayers([_base[l.key]], factor).first};
  }

  void markApplied() => applied = true;
}

/// Whether a tile shows the picture at its best layer: only the focused one does; grid and
/// strip tiles, for cameras and shares alike, take the 360p layer.
bool wantsHighVideo(String tileKey, String? focusKey) => focusKey != null && tileKey == focusKey;

/// Whether a remote video is received at all: the window must be showing and the tile on screen.
bool receivesVideo({required bool windowVisible, required bool tileOnScreen}) => windowVisible && tileOnScreen;

/// Removes from [m] every key not in [live]. For the per-track byte counters.
void pruneKeys<V>(Map<String, V> m, Set<String> live) => m.removeWhere((k, _) => !live.contains(k));
