import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

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
}

class LiveKitRoomAdapter implements RoomAdapter {
  final _signals = StreamController<RoomSignal>.broadcast();
  final _participants = StreamController<List<RoomParticipant>>.broadcast();
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _statsTimer;
  bool _sawRemoteAudio = false;
  bool _deafened = false;

  @override
  Stream<RoomSignal> get signals => _signals.stream;

  @override
  Stream<List<RoomParticipant>> get participants => _participants.stream;

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
        defaultAudioCaptureOptions: const AudioCaptureOptions(
          noiseSuppression: true,
          echoCancellation: true,
          autoGainControl: true,
        ),
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
    await _room?.localParticipant?.setMicrophoneEnabled(on);
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
    await _room?.localParticipant?.setCameraEnabled(on);
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
