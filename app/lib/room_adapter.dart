import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import 'capture_options.dart';
import 'video_options.dart';

/// Connection quality sample taken from the WebRTC stats.
class StatsSample {
  const StatsSample({this.rttMs, this.audioJitterMs, this.audioPacketsLost});
  final double? rttMs;
  final double? audioJitterMs;
  final int? audioPacketsLost;
}

/// Inbound video as received by this client.
class VideoRxSample {
  const VideoRxSample({this.width, this.height, this.framesPerSecond});
  final int? width;
  final int? height;
  final double? framesPerSecond;
}

sealed class RoomSignal {
  const RoomSignal();
  static const disconnected = RoomDisconnected();
  static const firstRemoteAudio = FirstRemoteAudio();
}

class RoomDisconnected extends RoomSignal {
  const RoomDisconnected();
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
  Future<void> connect(String url, String token, Uint8List e2eeKey);
  Future<void> disconnect();
  Future<void> setMicrophoneEnabled(bool on);

  /// Turns playback of every remote audio track off (and back on), as Discord's deafen.
  Future<void> setDeafened(bool on);
  Future<void> setCameraEnabled(bool on);
  Future<void> setScreenShareEnabled(bool on, {String? sourceId});
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

  /// The level of your own microphone, 0 to 1, about ten times a second while someone listens
  /// and you are in a call.
  Stream<double> get inputLevel;
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
  String? _outputId;
  String? _cameraId;
  double _master = 1;
  final _userVolume = <String, double>{};
  final _localMuted = <String>{};
  late final _levels = StreamController<double>.broadcast(
    onListen: () => _levelTimer ??=
        Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_sampleLevel())),
    onCancel: () {
      _levelTimer?.cancel();
      _levelTimer = null;
    },
  );
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
    final opts = captureOptionsFor(id);
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
  Stream<double> get inputLevel => _levels.stream;

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
            if (level is num) _levels.add(level.toDouble().clamp(0.0, 1.0));
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
  Future<void> connect(String url, String token, Uint8List e2eeKey) async {
    await disconnect();
    // Every member derives the same key, so the shared-key provider is enough.
    final keyProvider = await BaseKeyProvider.create();
    await keyProvider.setSharedKey(base64.encode(e2eeKey));
    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioCaptureOptions: captureOptionsFor(_inputId),
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
      connectOptions: const ConnectOptions(autoSubscribe: false),
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
      final watched = pub.participant.getTrackPublicationBySource(TrackSource.screenShareVideo)?.subscribed ?? false;
      if (watched) unawaited(pub.subscribe());
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
    await _room?.localParticipant?.setMicrophoneEnabled(on, audioCaptureOptions: captureOptionsFor(_inputId));
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
    await local.publishVideoTrack(track, publishOptions: cameraPublishOptions);
  }

  @override
  Future<void> setScreenShareEnabled(bool on, {String? sourceId}) async {
    final local = _room?.localParticipant;
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
      tracks = await LocalVideoTrack.createScreenShareTracksWithAudio(capture);
    } catch (e) {
      debugPrint('hubbub: screen capture with audio failed ($e), trying video only');
      tracks = [await LocalVideoTrack.createScreenShareTrack(capture)];
    }
    final publish = screenPublishOptionsFor(av1: await _canSendAv1());
    for (final t in tracks) {
      if (t is LocalVideoTrack) {
        await local.publishVideoTrack(t, publishOptions: publish);
      } else if (t is LocalAudioTrack) {
        await local.publishAudioTrack(t);
      }
    }
  }

  Future<bool> _canSendAv1() async {
    try {
      final caps = await rtc.getRtpSenderCapabilities('video');
      return canSendAv1([for (final c in caps.codecs ?? const <rtc.RTCRtpCodecCapability>[]) c.mimeType]);
    } catch (e) {
      debugPrint('hubbub: codec capabilities unavailable: $e');
      return false;
    }
  }

  @override
  Future<void> subscribeVideo(String participantId, String trackSid, bool on) async {
    final p = _room?.remoteParticipants[participantId];
    final pub = p?.trackPublications[trackSid];
    if (pub == null) return;
    if (on) {
      await pub.subscribe();
    } else {
      await pub.unsubscribe();
    }
  }

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

  /// Samples the first remote audio and video track; the public API has no RTT.
  Future<void> _sampleStats() async {
    final room = _room;
    if (room == null) return;
    try {
      double? jitter;
      int? lost;
      VideoRxSample? video;
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.trackPublications.values) {
          final track = pub.track;
          if (track is RemoteAudioTrack && jitter == null) {
            final st = await track.getReceiverStats();
            if (st != null) {
              jitter = st.jitter?.toDouble();
              if (jitter != null) jitter *= 1000;
              lost = st.packetsLost?.toInt();
            }
          } else if (track is RemoteVideoTrack && video == null) {
            final st = await track.getReceiverStats();
            if (st != null) {
              video = VideoRxSample(
                width: st.frameWidth?.toInt(),
                height: st.frameHeight?.toInt(),
                framesPerSecond: st.framesPerSecond?.toDouble(),
              );
            }
          }
        }
      }
      _signals.add(RoomStats(StatsSample(audioJitterMs: jitter, audioPacketsLost: lost)));
      if (video != null) _signals.add(RoomVideoRx(video));
    } catch (e) {
      debugPrint('stats sample failed: $e');
    }
  }
}
