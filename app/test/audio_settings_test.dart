import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/capture_options.dart';
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

  group('input processing prefs', () {
    test('default_to_full_input_volume_and_rnnoise', () {
      const p = AudioPrefs();
      expect(p.inputGain, 1.0);
      expect(p.noiseSuppression, NoiseSuppression.rnnoise);
    });

    test('round_trip_through_the_file_with_the_output_levels', () async {
      final dir = Directory.systemTemp.createTempSync('audioprefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AudioPrefsStore.file('${dir.path}/audio.json');
      await store.save(const AudioPrefs(
          master: 1.5, inputGain: 0.35, noiseSuppression: NoiseSuppression.standard));
      final back = await AudioPrefsStore.file('${dir.path}/audio.json').load();
      expect(back.inputGain, 0.35);
      expect(back.noiseSuppression, NoiseSuppression.standard);
      expect(back.master, 1.5);
    });

    test('an_old_file_without_them_loads_the_defaults_and_bad_values_are_clamped', () {
      final old = AudioPrefs.fromJson({'master': 0.5});
      expect((old.inputGain, old.noiseSuppression), (1.0, NoiseSuppression.rnnoise));
      final bad = AudioPrefs.fromJson({'inputGain': 7, 'noiseSuppression': 'krisp'});
      expect((bad.inputGain, bad.noiseSuppression), (2.0, NoiseSuppression.rnnoise));
      expect(AudioPrefs.fromJson({'inputGain': -1}).inputGain, 0.0);
    });
  });

  group('low light frame rate setting', () {
    test('is_on_by_default_and_for_old_files_and_junk', () {
      expect(const AudioPrefs().lowLightFullFrameRate, isTrue);
      expect(AudioPrefs.fromJson({'master': 0.5}).lowLightFullFrameRate, isTrue);
      expect(AudioPrefs.fromJson({'lowLightFullFrameRate': 'no'}).lowLightFullFrameRate, isTrue);
      expect(AudioPrefs.fromJson({'lowLightFullFrameRate': false}).lowLightFullFrameRate, isFalse);
    });

    test('off_is_saved_and_loaded_and_handed_to_the_room_at_start_and_every_join', () async {
      final room = FakeRoom();
      final store = AudioPrefsStore.memory();
      final audio = AudioSettings(room, store);
      await audio.start();
      expect(room.lowLightFullFrameRate, isTrue);
      await audio.setLowLightFullFrameRate(false);
      expect(room.lowLightFullFrameRate, isFalse);
      expect((await store.load()).lowLightFullFrameRate, isFalse);
      expect(AudioPrefs.fromJson((await store.load()).toJson()).lowLightFullFrameRate, isFalse);

      final room2 = FakeRoom();
      final again = AudioSettings(room2, store);
      await again.start();
      expect(again.lowLightFullFrameRate, isFalse);
      expect(room2.lowLightFullFrameRate, isFalse);
      room2.lowLightFullFrameRate = true;
      await again.applyForJoin();
      expect(room2.lowLightFullFrameRate, isFalse);
    });
  });

  group('audio settings', () {
    test('the_input_volume_slider_reaches_the_room_and_is_saved_on_commit', () async {
      final room = FakeRoom();
      final store = AudioPrefsStore.memory();
      final audio = AudioSettings(room, store);
      await audio.start();
      await audio.setInputGain(0.4);
      expect(audio.inputGain, 0.4);
      expect(room.inputGain, 0.4);
      await audio.setInputGain(9);
      await audio.commit();
      expect(audio.inputGain, 2.0);
      expect(room.inputGain, 2.0);
      expect((await store.load()).inputGain, 2.0);
    });

    test('choosing_a_suppressor_tells_the_room_and_is_saved', () async {
      final room = FakeRoom();
      final store = AudioPrefsStore.memory();
      final audio = AudioSettings(room, store);
      await audio.start();
      room.micCalls.clear();
      await audio.setNoiseSuppression(NoiseSuppression.standard);
      expect(room.micCalls, ['ns:standard']);
      expect(audio.noiseSuppression, NoiseSuppression.standard);
      expect((await store.load()).noiseSuppression, NoiseSuppression.standard);
    });

    test('a_start_and_every_join_hand_the_saved_input_levels_to_the_room', () async {
      final room = FakeRoom();
      final store = AudioPrefsStore.memory(const AudioPrefs(
          inputGain: 0.25, noiseSuppression: NoiseSuppression.none));
      final audio = AudioSettings(room, store);
      await audio.start();
      expect(room.inputGain, 0.25);
      expect(room.noiseSuppression, NoiseSuppression.none);
      room.inputGain = 1; // a fresh media stack knows nothing
      room.noiseSuppression = NoiseSuppression.rnnoise;
      await audio.applyForJoin();
      expect(room.inputGain, 0.25);
      expect(room.noiseSuppression, NoiseSuppression.none);
    });

    test('an_input_volume_drag_is_throttled_and_the_last_value_always_arrives', () async {
      final room = FakeRoom();
      final audio = AudioSettings(room, AudioPrefsStore.memory());
      await audio.start();
      room.micCalls.clear();
      for (var i = 1; i <= 10; i++) {
        await audio.setInputGain(i / 10);
      }
      expect(room.micCalls.length, lessThan(5));
      await audio.commit();
      expect(room.inputGain, 1.0);
    });
  });

  group('audio settings (output)', () {
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

    test('applying_while_dragging_is_throttled_and_commit_flushes_the_last_value', () async {
      for (var i = 1; i <= 10; i++) {
        await audio.setMaster(i / 10);
      }
      expect(room.volumeCalls.where((c) => c.startsWith('master:')).length, lessThan(5));
      await audio.commit();
      expect(room.masterVolume, 1.0, reason: 'the last value always reaches the room');
      expect((await store.load()).master, 1.0);
    });

    test('effective_volume_is_clamped_to_what_set_volume_accepts', () {
      expect(effectiveVolume(2, 2, false), 4);
      expect(effectiveVolume(10, 10, false), 10);
      expect(effectiveVolume(1, 1, true), 0);
    });
  });
}
