import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'capture_options.dart';
import 'publish_guard.dart';
import 'src/rust/api/hubbub.dart' show AppIceServer;
import 'video_options.dart';

/// The options for connecting to the tunnelled LiveKit signal URL.
///
/// LiveKit runs loopback-only, which libwebrtc will not use, so media goes through the node's
/// TURN shim: [ice] is its only ICE server and the policy is relay-only. The engine uses
/// `connectOptions.rtcConfiguration` for the first connection and for every reconnect, and
/// server-provided ICE servers apply only when this has none (livekit_client 2.13.1,
/// `lib/src/core/engine.dart:645-651`; the field is `ConnectOptions.rtcConfiguration`,
/// `lib/src/options.dart:209-224`).
ConnectOptions connectOptionsFor(AppIceServer? ice) {
  if (ice == null) return const ConnectOptions(autoSubscribe: false);
  return ConnectOptions(
    autoSubscribe: false,
    rtcConfiguration: RTCConfiguration(
      iceServers: [RTCIceServer(urls: [ice.url], username: ice.username, credential: ice.credential)],
      iceTransportPolicy: RTCIceTransportPolicy.relay,
    ),
  );
}

/// Connection quality sample taken from the WebRTC stats.
class StatsSample {
  const StatsSample({this.rttMs, this.audioJitterMs, this.audioPacketsLost});
  final double? rttMs;
  final double? audioJitterMs;
  final int? audioPacketsLost;
}

/// Inbound video as received by this client.
class VideoRxSample {
  const VideoRxSample({
    this.participantId,
    this.source = 'screen',
    this.width,
    this.height,
    this.framesPerSecond,
    this.kbps,
    this.framesDropped,
    this.decoder,
  });

  /// Whose stream this is.
  final String? participantId;

  /// `screen` or `camera`.
  final String source;
  final int? width;
  final int? height;
  final double? framesPerSecond;

  /// Received video bitrate over the last sampling interval.
  final double? kbps;

  /// Frames the decoder or renderer dropped since the stream began.
  final int? framesDropped;

  /// The decoder libwebrtc picked, e.g. `OpenH264`.
  final String? decoder;

  /// What the controller files this sample under: a participant's screen share is keyed by
  /// the participant alone, their camera by the participant and `camera`.
  String get key => source == 'screen' ? (participantId ?? '') : '${participantId ?? ''}/$source';
}

/// The `video_rx` log line the controller reads from the journal, e.g.
/// `video_rx from=bbbb 1920x1080 fps=59.6 kbps=5400 dropped=0 dec=OpenH264 src=screen`.
/// New fields are only ever appended, so older readers of the line keep working.
String formatVideoRx(VideoRxSample s) =>
    'video_rx from=${s.participantId ?? '?'} ${s.width ?? 0}x${s.height ?? 0} '
    'fps=${(s.framesPerSecond ?? 0).toStringAsFixed(1)} kbps=${(s.kbps ?? 0).round()} '
    'dropped=${s.framesDropped ?? 0} dec=${s.decoder ?? '-'} src=${s.source}';

/// One simulcast layer of a track this client sends.
class VideoTxLayer {
  const VideoTxLayer({
    this.rid,
    this.width,
    this.height,
    this.framesPerSecond,
    this.kbps,
    this.limitation,
    this.encoder,
  });

  /// The layer's simulcast id (`q`, `h`, `f`), null for a single layer.
  final String? rid;
  final int? width;
  final int? height;
  final double? framesPerSecond;
  final double? kbps;

  /// Why libwebrtc is holding the layer back: `none`, `cpu` or `bandwidth`.
  final String? limitation;

  /// The encoder libwebrtc picked, e.g. `OpenH264`.
  final String? encoder;
}

/// Outbound video as sent by this client: what the capturer delivers and what each layer
/// carries. `source` is `screen` or `camera`.
class VideoTxSample {
  const VideoTxSample({
    this.source = 'screen',
    this.captureWidth,
    this.captureHeight,
    this.captureFps,
    this.rttMs,
    this.layers = const [],
  });

  final String source;
  final int? captureWidth;
  final int? captureHeight;

  /// Frames per second the capturer hands to the encoder (`media-source`).
  final double? captureFps;

  /// Round trip to the server, from the transport's selected candidate pair.
  final double? rttMs;
  final List<VideoTxLayer> layers;
}

/// The `video_tx` log line, e.g.
/// `video_tx src=screen capture=1920x1080@59.8 rtt=3ms f=1920x1080@59.6/5400kbps/none/OpenH264 h=...`.
String formatVideoTx(VideoTxSample s) {
  final layers = [
    for (final l in s.layers)
      '${l.rid ?? '-'}=${l.width ?? 0}x${l.height ?? 0}@${(l.framesPerSecond ?? 0).toStringAsFixed(1)}'
          '/${(l.kbps ?? 0).round()}kbps/${l.limitation ?? '-'}/${l.encoder ?? '-'}',
  ];
  return [
    'video_tx src=${s.source}',
    'capture=${s.captureWidth ?? 0}x${s.captureHeight ?? 0}@${(s.captureFps ?? 0).toStringAsFixed(1)}',
    'rtt=${(s.rttMs ?? 0).round()}ms',
    ...layers,
  ].join(' ');
}

/// Reduces a sender's raw WebRTC stats to a [VideoTxSample]. [prev] holds the bytes sent and
/// the time ([nowMs], milliseconds) per layer from the last call, and is updated, for the layer bitrates.
VideoTxSample videoTxFromReports(
  String source,
  Iterable<rtc.StatsReport> reports,
  Map<String, (num, num)> prev, {
  required num nowMs,
}) {
  num? n(Object? v) => v is num ? v : (v == null ? null : num.tryParse('$v'));
  int? capW, capH;
  double? capFps, rtt;
  final layers = <VideoTxLayer>[];
  for (final r in reports) {
    final v = r.values;
    if (r.type == 'media-source' && v['kind'] == 'video') {
      capW = n(v['width'])?.toInt();
      capH = n(v['height'])?.toInt();
      capFps = n(v['framesPerSecond'])?.toDouble();
    } else if (r.type == 'outbound-rtp' && v['kind'] == 'video') {
      final bytes = n(v['bytesSent']);
      // Report timestamps are not in one unit across platforms, so the caller's clock times it.
      final at = nowMs;
      double? kbps;
      if (bytes != null) {
        final last = prev[r.id];
        if (last != null && at > last.$2) kbps = (bytes - last.$1) * 8 / (at - last.$2);
        prev[r.id] = (bytes, at);
      }
      layers.add(VideoTxLayer(
        rid: v['rid'] as String?,
        width: n(v['frameWidth'])?.toInt(),
        height: n(v['frameHeight'])?.toInt(),
        framesPerSecond: n(v['framesPerSecond'])?.toDouble(),
        kbps: kbps,
        limitation: v['qualityLimitationReason'] as String?,
        encoder: v['encoderImplementation'] as String?,
      ));
    } else if (r.type == 'candidate-pair' && (v['nominated'] == true || v['state'] == 'succeeded')) {
      final t = n(v['currentRoundTripTime']);
      if (t != null) rtt = t * 1000.0;
    }
  }
  return VideoTxSample(
    source: source,
    captureWidth: capW,
    captureHeight: capH,
    captureFps: capFps,
    rttMs: rtt,
    layers: layers,
  );
}

/// Scales a published share's layers down by the real capture size ([captureDownscale]).
/// The size is read from the top layer's first encoded frames (`media-source` carries none
/// in this libwebrtc) times that layer's current scale, so running it twice changes nothing
/// more; it is applied once per track.
Future<void> fitShareToCapture(LocalVideoTrack t) async {
  try {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final sender = t.sender;
      if (sender == null) return;
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) continue;
      // The top layer is the one scaled the least.
      final top = encodings.reduce((a, b) => (a.scaleResolutionDownBy ?? 1) <= (b.scaleResolutionDownBy ?? 1) ? a : b);
      // The sender's parameters carry no rids on Windows, so the top layer is found as the
      // largest outbound picture and the one encoding scaled the least.
      int? w, h;
      for (final r in await sender.getStats()) {
        if (r.type != 'outbound-rtp' || r.values['kind'] != 'video') continue;
        final fw = r.values['frameWidth'], fh = r.values['frameHeight'];
        if (fw is num && fh is num && fw > 0 && fh > 0 && fw * fh > (w ?? 0) * (h ?? 0)) {
          w = fw.toInt();
          h = fh.toInt();
        }
      }
      if (w == null || h == null) continue;
      final scale = top.scaleResolutionDownBy ?? 1;
      final factor = captureDownscale(w * scale, h * scale);
      if (factor <= 1.001) return;
      final scaled = scaledLayers([for (final e in encodings) e.scaleResolutionDownBy], factor);
      for (var k = 0; k < encodings.length; k++) {
        encodings[k].scaleResolutionDownBy = scaled[k];
      }
      params.encodings = encodings;
      final ok = await sender.setParameters(params);
      debugPrint('hubbub: share setParameters -> $ok');
      debugPrint('hubbub: share capture ${(w * scale).round()}x${(h * scale).round()}, layers scaled down by ${factor.toStringAsFixed(2)}');
      return;
    }
  } catch (e) {
    debugPrint('hubbub: fitting the share layers failed: $e');
  }
}

sealed class RoomSignal {
  const RoomSignal();
  static const disconnected = RoomDisconnected();
  static const firstRemoteAudio = FirstRemoteAudio();
  static const shareEnded = ShareEnded();
}

class RoomDisconnected extends RoomSignal {
  const RoomDisconnected();
}

/// The captured screen or window went away (its window closed): the share is over.
class ShareEnded extends RoomSignal {
  const ShareEnded();
}

class FirstRemoteAudio extends RoomSignal {
  const FirstRemoteAudio();
}

class RoomStats extends RoomSignal {
  const RoomStats(this.sample);
  final StatsSample sample;
}

class RoomVideoRx extends RoomSignal {
  const RoomVideoRx(this.sample);
  final VideoRxSample sample;
}

class RoomVideoTx extends RoomSignal {
  const RoomVideoTx(this.sample);
  final VideoTxSample sample;
}

/// One published video track on a participant. [track] is null until there is something to
/// render: a remote screen share before you click Watch, and always in tests.
class VideoFeed {
  const VideoFeed(this.sid, {this.track});
  final String sid;
  final VideoTrack? track;
}

class RoomParticipant {
  const RoomParticipant({
    required this.id,
    required this.name,
    required this.speaking,
    required this.isLocal,
    this.muted = false,
    this.camera,
    this.share,
  });
  final String id;
  final String name;
  final bool speaking;
  final bool isLocal;

  /// No live microphone track.
  final bool muted;

  /// Their camera, when it is on.
  final VideoFeed? camera;

  /// Their screen share, when they are streaming.
  final VideoFeed? share;
}

/// Largest volume the UI offers (Discord's 200%), as a multiplier of the source level.
const maxVolume = 2.0;

/// The gain for one remote track: the master output volume times the person's own volume,
/// or silence when you muted them locally. `Helper.setVolume` takes 0 to 10 (flutter_webrtc
/// `rtc_audio_track.h:17`, "volume in [0-10]"), where 1 leaves the level as it is, so the
/// product (at most 2 x 2) is clamped to that range.
double effectiveVolume(double master, double user, bool localMuted) =>
    localMuted ? 0 : (master * user).clamp(0.0, 10.0);

enum DeviceKind { audioInput, audioOutput, videoInput }

/// A microphone, speaker or camera the OS offers. [label] can be empty before the OS has
/// granted access to the device names.
class MediaDeviceInfo {
  const MediaDeviceInfo(this.id, this.label, this.kind);
  final String id;
  final String label;
  final DeviceKind kind;
}

/// What the UI and node logic need from a media room, so LiveKit can be faked.
abstract class RoomAdapter {
  /// [ice] is the node's TURN shim, through which media reaches the host; see [connectOptionsFor].
  Future<void> connect(String url, String token, Uint8List e2eeKey, {AppIceServer? ice});
  Future<void> disconnect();
  Future<void> setMicrophoneEnabled(bool on);

  /// Turns playback of every remote audio track off (and back on), as Discord's deafen.
  Future<void> setDeafened(bool on);
  Future<void> setCameraEnabled(bool on);
  Future<void> setScreenShareEnabled(bool on, {String? sourceId});

  /// Before a rejoin: takes the running screen share off this room without stopping its
  /// capture, so [resumeScreenShare] can put the same stream on the next room (a Wayland
  /// share cannot be restarted without asking the user again). Does nothing when none runs.
  Future<void> holdScreenShare();

  /// Publishes the share kept by [holdScreenShare] on the current room. Throws when nothing
  /// is held or the publish fails (the capture is then stopped).
  Future<void> resumeScreenShare();

  /// Stops the capture kept by [holdScreenShare], when there is one.
  Future<void> releaseHeldScreenShare();
  Future<void> subscribeVideo(String participantId, String trackSid, bool on);

  /// Picks the simulcast layer for a subscribed video track: the 360p15 layer ([high] false,
  /// grid tiles) or the best one ([high] true, a focused tile).
  Future<void> setVideoQuality(String participantId, String trackSid, {required bool high});
  Stream<RoomSignal> get signals;
  Stream<List<RoomParticipant>> get participants;

  /// Every microphone, speaker and camera the OS offers right now.
  Future<List<MediaDeviceInfo>> listDevices();

  /// Fires when a device is plugged in or removed.
  Stream<void> get devicesChanged;

  /// Choose the device to use (null follows the OS default). Live when in a call, else kept
  /// for the next [connect] (the output is applied right after connecting).
  Future<void> setInputDevice(String? id);
  Future<void> setOutputDevice(String? id);

  /// Kept for [setCameraEnabled]; switches the running camera when there is one.
  Future<void> setCameraDevice(String? id);

  /// Output volume for everyone (1 is unchanged, up to [maxVolume]). Kept across calls and
  /// applied to every remote track, new ones as they arrive.
  Future<void> setMasterVolume(double v);

  /// One person's volume for you (1 is unchanged, up to [maxVolume]). Kept across calls.
  Future<void> setParticipantVolume(String id, double v);

  /// Stops (or resumes) your hearing of one person; they are not muted for anyone else.
  Future<void> setLocalMuteFor(String id, bool muted);

  /// Your microphone gain, 0 to [maxVolume] (1 is unchanged), applied in the capture path
  /// after noise suppression. Kept across calls.
  Future<void> setInputGain(double v);

  /// Which noise suppressor cleans your microphone. Live in a call (the capture restarts when
  /// the WebRTC suppressor has to change), else kept for the next [connect].
  Future<void> setNoiseSuppression(NoiseSuppression ns);

  /// The peaks of your own microphone, about twenty times a second while someone listens and
  /// you are in a call.
  Stream<MicLevels> get micLevels;
}

/// Peaks of the microphone over about 50 ms, as the capture path measures them.
class MicLevels {
  const MicLevels({required this.pre, required this.post, this.speech = -1, this.clip = 0});

  /// Peak (0 to 1) before noise suppression and gain: the true level the device delivered.
  final double pre;

  /// Peak (0 to 1) after gain and the limiter: what is sent.
  final double post;

  /// RNNoise speech probability, or -1 when RNNoise is off.
  final double speech;

  /// Share (0 to 1) of 10 ms blocks in the window whose [pre] peak was at least 0.98.
  final double clip;
}

class LiveKitRoomAdapter implements RoomAdapter {
  final _signals = StreamController<RoomSignal>.broadcast();
  final _participants = StreamController<List<RoomParticipant>>.broadcast();
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _statsTimer;
  bool _sawRemoteAudio = false;
  bool _deafened = false;
  String? _inputId;
  NoiseSuppression _ns = NoiseSuppression.rnnoise;
  String? _outputId;
  String? _cameraId;
  double _master = 1;
  final _userVolume = <String, double>{};
  final _localMuted = <String>{};
  // The patched plugin publishes true peaks; where it is absent (macOS) the level comes from
  // the sender stats instead.
  late final StreamController<MicLevels> _levels = StreamController<MicLevels>.broadcast(
    onListen: () {
      if (rtc.HubbubAudio.supported) {
        _peakSub ??= rtc.HubbubAudio.levels.listen((l) => _levels.add(MicLevels(
            pre: l.pre, post: l.post, speech: l.speech, clip: l.clip)));
        // What the capture path really looks like (rate, channels, bands, frames, skipped
        // blocks), for the log.
        _layoutSub ??= rtc.HubbubAudio.layout.listen((t) => debugPrint('hubbub: apm $t'));
      } else {
        _levelTimer ??=
            Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_sampleLevel()));
      }
    },
    onCancel: () {
      _peakSub?.cancel();
      _peakSub = null;
      _layoutSub?.cancel();
      _layoutSub = null;
      _levelTimer?.cancel();
      _levelTimer = null;
    },
  );
  StreamSubscription<rtc.HubbubLevels>? _peakSub;
  StreamSubscription<String>? _layoutSub;
  Timer? _levelTimer;
  bool _levelBusy = false;

  @override
  Stream<RoomSignal> get signals => _signals.stream;

  @override
  Stream<List<RoomParticipant>> get participants => _participants.stream;

  @override
  Stream<void> get devicesChanged => Hardware.instance.onDeviceChange.stream.map((_) {});

  @override
  Future<List<MediaDeviceInfo>> listDevices() async {
    final all = await Hardware.instance.enumerateDevices();
    final kinds = {
      'audioinput': DeviceKind.audioInput,
      'audiooutput': DeviceKind.audioOutput,
      'videoinput': DeviceKind.videoInput,
    };
    return [
      for (final d in all)
        if (kinds[d.kind] != null) MediaDeviceInfo(d.deviceId, d.label, kinds[d.kind]!),
    ];
  }

  /// The playback or camera device with [id]; when [id] is null or gone, the OS default.
  /// Desktop WebRTC lists no `default` id: it names devices by ADM index, and on Windows the
  /// first entries are the system "Default" (and "Communications") devices. So Default is an
  /// entry with id `default` or a label starting "Default", else the first entry (ADM index 0,
  /// the same device WebRTC itself opens when no id is given).
  Future<MediaDevice?> _resolve(String? id, String type) async {
    final all = await Hardware.instance.enumerateDevices(type: type);
    if (all.isEmpty) return null;
    if (id != null) {
      for (final d in all) {
        if (d.deviceId == id) return d;
      }
    }
    for (final d in all) {
      if (d.deviceId == 'default' || d.label.startsWith('Default')) return d;
    }
    return all.first;
  }

  /// In a call this restarts the local mic track on the new device: on desktop
  /// `Room.setAudioInputDevice` only calls the ADM setter, which a running recording ignores.
  /// A null id gives WebRTC no device, so it opens its default. A muted track only records
  /// the options (no capture starts) and the unmute restart uses them, so mute is kept.
  @override
  Future<void> setInputDevice(String? id) async {
    _inputId = id;
    final room = _room;
    if (room == null) return; // connect passes the id in its capture options
    await _restartCapture(room);
  }

  @override
  Future<void> setInputGain(double v) async {
    if (!rtc.HubbubAudio.supported) return;
    await rtc.HubbubAudio.setInputGain(v.clamp(0.0, maxVolume));
  }

  @override
  Future<void> setNoiseSuppression(NoiseSuppression ns) async {
    final before = effectiveNoiseSuppression(_ns);
    _ns = ns;
    if (rtc.HubbubAudio.supported) {
      await rtc.HubbubAudio.setNoiseSuppression(switch (effectiveNoiseSuppression(ns)) {
        NoiseSuppression.none => rtc.HubbubNoiseSuppression.off,
        NoiseSuppression.standard => rtc.HubbubNoiseSuppression.webrtc,
        NoiseSuppression.rnnoise => rtc.HubbubNoiseSuppression.rnnoise,
      });
    }
    final room = _room;
    // Only the standard suppressor is a capture constraint; moving to or from it restarts the
    // running mic track, the other two change inside the post-processor.
    final standard = effectiveNoiseSuppression(ns) == NoiseSuppression.standard;
    if (room != null && (before == NoiseSuppression.standard) != standard) {
      await _restartCapture(room);
    }
  }

  /// Applies the current device and suppressor to the running mic track (a muted track only
  /// records the options, the unmute restart uses them).
  Future<void> _restartCapture(Room room) async {
    final opts = captureOptionsFor(_inputId, noiseSuppression: _ns);
    for (final pub in room.localParticipant?.audioTrackPublications ?? const []) {
      final track = pub.track;
      if (track == null) continue;
      if (track.muted) {
        track.currentOptions = opts;
      } else {
        await track.restartTrack(opts);
      }
    }
  }

  @override
  Future<void> setOutputDevice(String? id) async {
    _outputId = id;
    await _applyOutput();
  }

  Future<void> _applyOutput() async {
    final d = await _resolve(_outputId, 'audiooutput');
    if (d == null) return;
    final room = _room;
    if (room != null) {
      await room.setAudioOutputDevice(d);
    } else {
      await Hardware.instance.selectAudioOutput(d);
    }
  }

  @override
  Future<void> setMasterVolume(double v) {
    _master = v;
    return _applyVolumes();
  }

  @override
  Future<void> setParticipantVolume(String id, double v) {
    _userVolume[id] = v;
    return _applyVolumes(only: id);
  }

  @override
  Future<void> setLocalMuteFor(String id, bool muted) {
    muted ? _localMuted.add(id) : _localMuted.remove(id);
    return _applyVolumes(only: id);
  }

  /// Gives each remote audio track its gain: master x the person's volume, or 0 when muted
  /// locally. Run again whenever a track (re)subscribes, after connecting, and on undeafen.
  Future<void> _applyVolumes({String? only}) async {
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      if (only != null && p.identity != only) continue;
      final v = effectiveVolume(_master, _userVolume[p.identity] ?? 1, _localMuted.contains(p.identity));
      for (final pub in p.audioTrackPublications) {
        final track = pub.track;
        if (track != null) await _setTrackVolume(track, v);
      }
    }
  }

  static Future<void> _setTrackVolume(RemoteAudioTrack track, double v) async {
    try {
      await rtc.Helper.setVolume(v, track.mediaStreamTrack);
    } catch (e) {
      debugPrint('audio volume change failed: $e');
    }
  }

  @override
  Stream<MicLevels> get micLevels => _levels.stream;

  /// Reads the local microphone's `audioLevel` (0 to 1) from the sender's stats.
  Future<void> _sampleLevel() async {
    if (_levelBusy) return;
    _levelBusy = true;
    try {
      for (final pub in _room?.localParticipant?.audioTrackPublications ?? const []) {
        final stats = await pub.track?.sender?.getStats() ?? const <rtc.StatsReport>[];
        for (final r in stats) {
          if (r.type == 'media-source' && r.values['kind'] == 'audio') {
            final level = r.values['audioLevel'];
            if (level is num) {
              final l = level.toDouble().clamp(0.0, 1.0);
              _levels.add(MicLevels(pre: l, post: l));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('mic level sample failed: $e');
    } finally {
      _levelBusy = false;
    }
  }

  @override
  Future<void> setCameraDevice(String? id) async {
    _cameraId = id;
    final room = _room;
    if (room == null) return;
    final d = await _resolve(id, 'videoinput');
    if (d != null) await room.setVideoInputDevice(d);
  }

  @override
  Future<void> connect(String url, String token, Uint8List e2eeKey, {AppIceServer? ice}) async {
    await disconnect();
    // Every member derives the same key, so the shared-key provider is enough.
    final keyProvider = await BaseKeyProvider.create();
    await keyProvider.setSharedKey(base64.encode(e2eeKey));
    final room = Room(
      roomOptions: RoomOptions(
        // Off: with it on, the layer follows the size of the view, so a watched share in a
        // normal window got 720p30 whatever setVideoQuality said. The app picks the layer
        // itself (grid cameras LOW, a focused camera and every watched share HIGH) and
        // already subscribes only to what is on screen.
        adaptiveStream: false,
        dynacast: true,
        defaultAudioCaptureOptions: captureOptionsFor(_inputId, noiseSuppression: _ns),
        e2eeOptions: E2EEOptions(keyProvider: keyProvider),
      ),
    );
    _room = room;
    _sawRemoteAudio = false;
    _listener = room.createListener()
      ..on<RoomDisconnectedEvent>((_) {
        _signals.add(RoomSignal.disconnected);
        _emitParticipants();
      })
      ..on<TrackPublishedEvent>((e) => _autoSubscribe(e.publication))
      ..on<TrackSubscribedEvent>((e) {
        final track = e.track;
        if (track is VideoTrack) {
          // Grid tiles take the 360p15 layer; a focused tile asks for more.
          if (e.publication.source == TrackSource.camera) {
            unawaited(e.publication.setVideoQuality(
                _highVideo.contains(e.publication.sid) ? VideoQuality.HIGH : VideoQuality.LOW));
          } else if (e.publication.source == TrackSource.screenShareVideo) {
            // A share is only subscribed while watched, and a watched share gets its best
            // layer whatever size its view is.
            unawaited(e.publication.setVideoQuality(VideoQuality.HIGH));
          }
          _emitParticipants();
        }
        if (track is RemoteAudioTrack) {
          if (_deafened) _setPlayback(track, false);
          unawaited(_applyVolumes(only: e.participant.identity));
        }
        if (e.track.kind == TrackType.AUDIO && !_sawRemoteAudio) {
          _sawRemoteAudio = true;
          _signals.add(RoomSignal.firstRemoteAudio);
        }
      })
      ..on<TrackUnsubscribedEvent>((_) => _emitParticipants())
      ..on<ParticipantConnectedEvent>((_) => _emitParticipants())
      ..on<ParticipantDisconnectedEvent>((_) => _emitParticipants())
      ..on<ActiveSpeakersChangedEvent>((_) => _emitParticipants())
      // Mute state shows on the participants, so changes to it re-emit them.
      ..on<TrackMutedEvent>((_) => _emitParticipants())
      ..on<TrackUnmutedEvent>((_) => _emitParticipants())
      ..on<TrackPublishedEvent>((_) => _emitParticipants())
      ..on<TrackUnpublishedEvent>((_) => _emitParticipants())
      ..on<LocalTrackPublishedEvent>((_) => _emitParticipants())
      ..on<LocalTrackUnpublishedEvent>((_) => _emitParticipants());
    await room.connect(
      url,
      token,
      connectOptions: connectOptionsFor(ice),
    );
    // Tracks published before we joined do not raise TrackPublishedEvent.
    for (final p in room.remoteParticipants.values) {
      p.trackPublications.values.forEach(_autoSubscribe);
    }
    await _applyOutput();
    await _applyVolumes();
    _emitParticipants();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sampleStats());
  }

  /// What is received without asking: voice, and cameras (at the low layer, see above). A
  /// screen share, and its audio, wait for the person to click Watch ([subscribeVideo]).
  void _autoSubscribe(RemoteTrackPublication pub) {
    final source = pub.source;
    if (source == TrackSource.screenShareVideo) return;
    if (source == TrackSource.screenShareAudio) {
      // Joins a stream that is already being watched.
      if (_watchedShares.contains(pub.participant.identity)) unawaited(pub.subscribe());
      return;
    }
    if (pub.kind == TrackType.AUDIO || source == TrackSource.camera) unawaited(pub.subscribe());
  }

  /// Camera tracks (by sid) the UI has asked to see at full quality.
  final _highVideo = <String>{};

  /// Ends the app's use of the adapter: stops the meter's polling and closes its stream.
  Future<void> dispose() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    await _peakSub?.cancel();
    _peakSub = null;
    await _layoutSub?.cancel();
    _layoutSub = null;
    await _levels.close();
    await disconnect();
    await _signals.close();
    await _participants.close();
  }

  @override
  Future<void> disconnect() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _listener?.dispose();
    _listener = null;
    _watchedShares.clear();
    final room = _room;
    _room = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
      _emitParticipants();
    }
  }

  @override
  Future<void> setMicrophoneEnabled(bool on) async {
    // Explicit options, so a track created after a live device change uses that device.
    await _room?.localParticipant?.setMicrophoneEnabled(on, audioCaptureOptions: captureOptionsFor(_inputId, noiseSuppression: _ns));
  }

  @override
  Future<void> setDeafened(bool on) async {
    _deafened = on;
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final track = pub.track;
        if (track != null) _setPlayback(track, !on);
      }
    }
    if (!on) await _applyVolumes();
  }

  /// Track.enable/disable do nothing before the track starts, and a track is subscribed
  /// (and announced) before it starts, so this sets the media track directly.
  static void _setPlayback(RemoteAudioTrack track, bool on) {
    try {
      track.mediaStreamTrack.enabled = on;
    } catch (e) {
      debugPrint('audio playback toggle failed: $e');
    }
  }

  @override
  Future<void> setCameraEnabled(bool on) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    // Off unpublishes (and stops the capture), so the next On opens the camera chosen by then.
    final old = local.getTrackPublicationBySource(TrackSource.camera);
    if (old != null) await local.removePublishedTrack(old.sid);
    if (!on) return;
    final device = await _resolve(_cameraId, 'videoinput');
    final track = await LocalVideoTrack.createCameraTrack(cameraCaptureOptionsFor(device?.deviceId));
    await publishAllOrNone([
      PublishStep(
        publish: () async => (await local.publishVideoTrack(track, publishOptions: cameraPublishOptions)).sid,
        stop: track.stop,
      ),
    ], unpublish: local.removePublishedTrack);
  }

  /// The screen share tracks [holdScreenShare] took off the old room.
  List<LocalTrack>? _heldShare;

  @override
  Future<void> holdScreenShare() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final held = <LocalTrack>[];
    for (final source in [TrackSource.screenShareVideo, TrackSource.screenShareAudio]) {
      final pub = local.getTrackPublicationBySource(source);
      final track = pub?.track;
      if (pub == null || track == null) continue;
      // Not removePublishedTrack: that stops the capture. The room is about to be closed, which
      // takes the sender with it; LiveKit's own re-publish after a reconnect reuses tracks the
      // same way.
      local.trackPublications.remove(pub.sid);
      held.add(track);
    }
    // A second hold (a rejoin that restarted) finds nothing published and keeps the first.
    if (held.isNotEmpty) _heldShare = held;
  }

  @override
  Future<void> resumeScreenShare() async {
    final held = _heldShare;
    _heldShare = null;
    final local = _room?.localParticipant;
    if (held == null || local == null) throw StateError('no screen share to resume');
    final publish = screenPublishOptionsFor();
    await publishAllOrNone([
      for (final t in held)
        PublishStep(
          publish: () async {
            if (t is LocalVideoTrack) {
              // Senders of the old room's connection: LiveKit clears them the same way (its
              // internal clearSimulcastState) before it re-publishes after a reconnect.
              t.simulcastCodecs.clear();
              t.encodingBackups.clear();
              final sid = (await local.publishVideoTrack(t, publishOptions: publish)).sid;
              unawaited(fitShareToCapture(t));
              return sid;
            }
            return (await local.publishAudioTrack(t as LocalAudioTrack)).sid;
          },
          stop: t.stop,
        ),
    ], unpublish: local.removePublishedTrack);
  }

  @override
  Future<void> releaseHeldScreenShare() async {
    final held = _heldShare;
    _heldShare = null;
    for (final t in held ?? const <LocalTrack>[]) {
      try {
        await t.stop();
      } catch (e) {
        debugPrint('hubbub: stopping the kept screen share failed: $e');
      }
    }
  }

  @override
  Future<void> setScreenShareEnabled(bool on, {String? sourceId}) async {
    final local = _room?.localParticipant;
    await releaseHeldScreenShare();
    if (local == null) return;
    for (final source in [TrackSource.screenShareVideo, TrackSource.screenShareAudio]) {
      final old = local.getTrackPublicationBySource(source);
      if (old != null) await local.removePublishedTrack(old.sid);
    }
    if (!on) return;
    final capture = screenCaptureOptionsFor(sourceId);
    // The app's (Windows) or the system's (Linux) audio goes along where the platform has it;
    // when the capture with audio is refused, share the picture alone.
    List<LocalTrack> tracks;
    try {
      tracks = shareAudioSupported(isLinux: Platform.isLinux)
          ? await LocalVideoTrack.createScreenShareTracksWithAudio(capture)
          : [await LocalVideoTrack.createScreenShareTrack(capture)];
    } catch (e) {
      debugPrint('hubbub: screen capture with audio failed ($e), trying video only');
      tracks = [await LocalVideoTrack.createScreenShareTrack(capture)];
    }
    final publish = screenPublishOptionsFor();
    await publishAllOrNone([
      for (final t in tracks)
        PublishStep(
          publish: () async {
            if (t is! LocalVideoTrack) return (await local.publishAudioTrack(t as LocalAudioTrack)).sid;
            final sid = (await local.publishVideoTrack(t, publishOptions: publish)).sid;
            unawaited(fitShareToCapture(t));
            return sid;
          },
          stop: t.stop,
        ),
    ], unpublish: local.removePublishedTrack);
    // (The desktop plugin never raises the track's `onEnded`, so the UI watches whether the
    // shared window still exists instead; see HomePage._watchShare.)
  }

  @override
  Future<void> subscribeVideo(String participantId, String trackSid, bool on) async {
    final p = _room?.remoteParticipants[participantId];
    final pub = p?.trackPublications[trackSid];
    if (p == null || pub == null) return;
    // A share's sound goes with its picture: same click, and it follows a late-arriving track.
    final isShare = pub.source == TrackSource.screenShareVideo;
    if (isShare) on ? _watchedShares.add(participantId) : _watchedShares.remove(participantId);
    final audio = isShare ? p.getTrackPublicationBySource(TrackSource.screenShareAudio) : null;
    if (on) {
      await pub.subscribe();
      await audio?.subscribe();
    } else {
      await pub.unsubscribe();
      await audio?.unsubscribe();
    }
  }

  /// Participants whose share the UI is watching (their share audio is subscribed too).
  final _watchedShares = <String>{};

  @override
  Future<void> setVideoQuality(String participantId, String trackSid, {required bool high}) async {
    high ? _highVideo.add(trackSid) : _highVideo.remove(trackSid);
    final pub = _room?.remoteParticipants[participantId]?.trackPublications[trackSid];
    if (pub is RemoteTrackPublication) {
      await pub.setVideoQuality(high ? VideoQuality.HIGH : VideoQuality.LOW);
    }
  }

  /// No live microphone (a screen share's audio track does not count).
  static bool _micMuted(Participant p) => p.getTrackPublicationBySource(TrackSource.microphone)?.muted ?? true;

  /// [source]'s video on [p], when there is something to show: a camera needs its track (so
  /// a tile never shows a black box), a share shows as soon as it is announced.
  static VideoFeed? _feed(Participant p, TrackSource source) {
    final pub = p.getTrackPublicationBySource(source);
    if (pub == null) return null;
    final track = pub.track;
    final video = track is VideoTrack ? track : null;
    if (source == TrackSource.camera && (video == null || pub.muted)) return null;
    return VideoFeed(pub.sid, track: video);
  }

  void _emitParticipants() {
    final room = _room;
    final list = <RoomParticipant>[];
    final local = room?.localParticipant;
    if (room != null && local != null) {
      list.add(RoomParticipant(
        id: local.identity,
        name: local.name.isEmpty ? local.identity : local.name,
        speaking: local.isSpeaking,
        isLocal: true,
        muted: _micMuted(local),
        camera: _feed(local, TrackSource.camera),
        share: _feed(local, TrackSource.screenShareVideo),
      ));
      for (final p in room.remoteParticipants.values) {
        list.add(RoomParticipant(
          id: p.identity,
          name: p.name.isEmpty ? p.identity : p.name,
          speaking: p.isSpeaking,
          isLocal: false,
          muted: _micMuted(p),
          camera: _feed(p, TrackSource.camera),
          share: _feed(p, TrackSource.screenShareVideo),
        ));
      }
    }
    _participants.add(list);
  }

  /// Bytes received and when, per subscribed video, for the bitrate between two samples.
  final _rxPrev = <String, (num, DateTime)>{};

  /// Bytes sent and the report time per outbound layer, for [videoTxFromReports].
  final _txPrev = <String, (num, num)>{};

  static String? _videoSource(TrackSource source) => switch (source) {
        TrackSource.screenShareVideo => 'screen',
        TrackSource.camera => 'camera',
        _ => null,
      };

  /// Samples the first remote audio track, every subscribed remote video (camera and screen
  /// share; a share's track exists only after Watch) and every video this client publishes;
  /// the public API has no RTT.
  Future<void> _sampleStats() async {
    final room = _room;
    if (room == null) return;
    try {
      double? jitter;
      int? lost;
      final videos = <VideoRxSample>[];
      final sent = <VideoTxSample>[];
      final live = <String>{};
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          final track = pub.track;
          if (track is RemoteAudioTrack && jitter == null) {
            final st = await track.getReceiverStats();
            if (st != null) {
              jitter = st.jitter?.toDouble();
              if (jitter != null) jitter *= 1000;
              lost = st.packetsLost?.toInt();
            }
          }
        }
        for (final pub in p.videoTrackPublications) {
          final source = _videoSource(pub.source);
          final track = pub.track;
          if (source == null || track is! RemoteVideoTrack) continue;
          live.add(pub.sid);
          final st = await track.getReceiverStats();
          if (st == null) continue;
          final now = DateTime.now();
          final bytes = st.bytesReceived;
          final prev = _rxPrev[pub.sid];
          double? kbps;
          if (bytes != null) {
            if (prev != null) {
              final secs = now.difference(prev.$2).inMilliseconds / 1000;
              if (secs > 0) kbps = (bytes - prev.$1) * 8 / 1000 / secs;
            }
            _rxPrev[pub.sid] = (bytes, now);
          }
          videos.add(VideoRxSample(
            participantId: p.identity,
            source: source,
            width: st.frameWidth?.toInt(),
            height: st.frameHeight?.toInt(),
            framesPerSecond: st.framesPerSecond?.toDouble(),
            kbps: kbps,
            framesDropped: st.framesDropped?.toInt(),
            decoder: st.decoderImplementation,
          ));
        }
      }
      for (final pub in room.localParticipant?.videoTrackPublications ?? <LocalTrackPublication<LocalVideoTrack>>[]) {
        final source = _videoSource(pub.source);
        final reports = await pub.track?.sender?.getStats();
        if (source == null || reports == null) continue;
        sent.add(videoTxFromReports(source, reports, _txPrev, nowMs: DateTime.now().millisecondsSinceEpoch));
      }
      _rxPrev.removeWhere((sid, _) => !live.contains(sid));
      _signals.add(RoomStats(StatsSample(audioJitterMs: jitter, audioPacketsLost: lost)));
      for (final v in videos) {
        _signals.add(RoomVideoRx(v));
      }
      for (final v in sent) {
        _signals.add(RoomVideoTx(v));
      }
    } catch (e) {
      debugPrint('stats sample failed: $e');
    }
  }
}
