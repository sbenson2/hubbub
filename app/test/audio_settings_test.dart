import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/room_adapter.dart';

import 'support/fakes.dart';

void main() {
  group('prefs file', () {
    test('round_trips_master_volumes_and_mutes', () async {
      final dir = Directory.systemTemp.createTempSync('audioprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AudioPrefsStore.file('${dir.path}/audio.json');
      expect((await store.load()).master, 1);
      await store.save(const AudioPrefs(master: 1.5, volumes: {'bbbb': 0.25}, muted: {'cccc'}));
      final back = await AudioPrefsStore.file('${dir.path}/audio.json').load();
      expect(back.master, 1.5);
      expect(back.volumes, {'bbbb': 0.25});
      expect(back.muted, {'cccc'});
    });

    test('a_corrupt_file_loads_as_everything_at_100_percent', () async {
      final dir = Directory.systemTemp.createTempSync('audioprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/audio.json').writeAsStringSync('{nope');
      final p = await AudioPrefsStore.file('${dir.path}/audio.json').load();
      expect(p.master, 1.0);
      expect(p.volumes, isEmpty);
      expect(p.muted, isEmpty);
    });

    test('out_of_range_values_are_clamped_on_load', () {
      final p = AudioPrefs.fromJson({'master': 9, 'volumes': {'a': -3}});
      expect((p.master, p.volumes['a']), (2.0, 0.0));
    });
  });

  group('audio settings', () {
    late FakeRoom room;
    late AudioPrefsStore store;
    late AudioSettings audio;

    setUp(() async {
      room = FakeRoom();
      store = AudioPrefsStore.memory();
      audio = AudioSettings(room, store);
      await audio.start();
    });

    test('the_track_gain_is_master_times_the_persons_own_volume', () async {
      await audio.setVolume('bbbb', 0.5);
      await audio.setMaster(1.5);
      expect(room.effectiveFor('bbbb'), closeTo(0.75, 1e-9));
      expect(room.effectiveFor('cccc'), closeTo(1.5, 1e-9), reason: 'others follow the master only');
    });

    test('a_local_mute_silences_that_person_only_and_unmute_restores_their_volume', () async {
      await audio.setVolume('bbbb', 0.5);
      await audio.setLocalMute('bbbb', true);
      expect(room.effectiveFor('bbbb'), 0);
      expect(room.effectiveFor('cccc'), 1);
      expect(audio.isLocallyMuted('bbbb'), isTrue);
      await audio.setLocalMute('bbbb', false);
      expect(room.effectiveFor('bbbb'), closeTo(0.5, 1e-9));
    });

    test('volumes_above_200_percent_are_clamped', () async {
      await audio.setMaster(5);
      await audio.setVolume('bbbb', 3);
      expect(audio.master, 2);
      expect(audio.volumeOf('bbbb'), 2);
    });

    test('levels_are_saved_on_commit_and_loaded_by_the_next_start', () async {
      await audio.setMaster(1.25);
      await audio.setVolume('bbbb', 0.4);
      await audio.setLocalMute('cccc', true);
      await audio.commit();
      final saved = await store.load();
      expect(saved.master, 1.25);
      expect(saved.volumes['bbbb'], 0.4);
      expect(saved.muted, {'cccc'});

      final room2 = FakeRoom();
      final again = AudioSettings(room2, store);
      await again.start();
      expect(again.master, 1.25);
      expect(again.volumeOf('bbbb'), 0.4);
      expect(room2.effectiveFor('bbbb'), closeTo(0.5, 1e-9));
      expect(room2.effectiveFor('cccc'), 0);
    });

    test('a_join_hands_every_saved_level_to_the_room_again', () async {
      await audio.setMaster(0.5);
      await audio.setVolume('bbbb', 0.5);
      await audio.setLocalMute('cccc', true);
      room.volumeCalls.clear();
      room.masterVolume = 1; // a fresh media room knows nothing
      room.userVolumes.clear();
      room.localMutes.clear();
      await audio.applyForJoin();
      expect(room.masterVolume, 0.5);
      expect(room.effectiveFor('bbbb'), closeTo(0.25, 1e-9));
      expect(room.effectiveFor('cccc'), 0);
    });

    test('effective_volume_is_clamped_to_what_set_volume_accepts', () {
      expect(effectiveVolume(2, 2, false), 4);
      expect(effectiveVolume(10, 10, false), 10);
      expect(effectiveVolume(1, 1, true), 0);
    });
  });
}
