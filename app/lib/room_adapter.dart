import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import 'capture_options.dart';

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

class RoomParticipant {
  const RoomParticipant({
    required this.id,
    required this.name,
    required this.speaking,
    required this.isLocal,
    this.muted = false,
  });
  final String id;
  final String name;
  final bool speaking;
  final bool isLocal;

  /// No live microphone track.
  final bool muted;
}

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
      ..on<TrackPublishedEvent>((e) {
        // Audio is always wanted; video waits for an explicit subscribeVideo.
        if (e.publication.kind == TrackType.AUDIO) e.publication.subscribe();
      })
      ..on<TrackSubscribedEvent>((e) {
        final track = e.track;
        if (track is RemoteAudioTrack && _deafened) _setPlayback(track, false);
        if (e.track.kind == TrackType.AUDIO && !_sawRemoteAudio) {
          _sawRemoteAudio = true;
          _signals.add(RoomSignal.firstRemoteAudio);
        }
      })
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
      for (final pub in p.audioTrackPublications) {
        pub.subscribe();
      }
    }
    await _applyOutput();
    _emitParticipants();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sampleStats());
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
    await _room?.localParticipant?.setCameraEnabled(
      on,
      cameraCaptureOptions: _cameraId == null ? null : CameraCaptureOptions(deviceId: _cameraId),
    );
  }

  @override
  Future<void> setScreenShareEnabled(bool on, {String? sourceId}) async {
    await _room?.localParticipant?.setScreenShareEnabled(
      on,
      screenShareCaptureOptions:
          sourceId == null ? null : ScreenShareCaptureOptions(sourceId: sourceId),
    );
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
        muted: local.isMuted,
      ));
      for (final p in room.remoteParticipants.values) {
        list.add(RoomParticipant(
          id: p.identity,
          name: p.name.isEmpty ? p.identity : p.name,
          speaking: p.isSpeaking,
          isLocal: false,
          muted: p.isMuted,
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
