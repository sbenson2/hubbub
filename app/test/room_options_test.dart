import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/capture_options.dart';
import 'package:hubbub/room_adapter.dart';
import 'package:livekit_client/livekit_client.dart';

void main() {
  test('rooms_publish_voice_with_dtx_off_at_64_kbps', () async {
    final room = Room(roomOptions: hubbubRoomOptions(noiseSuppression: NoiseSuppression.none));
    final publish = room.roomOptions.defaultAudioPublishOptions;
    expect(publish.dtx, isFalse);
    expect(publish.encoding?.maxBitrate, 64000);
    // livekit forces RED off under E2EE whatever this says; keep its default
    expect(publish.red, isTrue);
    await room.dispose();
  });

  test('the_publish_options_are_the_ones_the_diagnostics_session_reports', () {
    expect(hubbubAudioPublishOptions.dtx, isFalse);
    expect(hubbubAudioPublishOptions.encoding, const AudioEncoding(maxBitrate: 64000));
  });

  test('share_audio_publish_options_are_explicit_and_match_voice', () {
    expect(hubbubShareAudioPublishOptions.dtx, isFalse);
    expect(hubbubShareAudioPublishOptions.encoding, const AudioEncoding(maxBitrate: 64000));
    expect(hubbubShareAudioPublishOptions.encoding, hubbubAudioPublishOptions.encoding);
    expect(hubbubShareAudioPublishOptions.dtx, hubbubAudioPublishOptions.dtx);
    // Both share publish paths (first share and re-publish after a reconnect) must pass the
    // options, or LiveKit falls back to the room's voice defaults.
    final calls = File('lib/room_adapter.dart')
        .readAsLinesSync()
        .where((l) => l.contains('.publishAudioTrack('))
        .toList();
    expect(calls, hasLength(2));
    for (final c in calls) {
      expect(c, contains('publishOptions: hubbubShareAudioPublishOptions'));
    }
  });
}
