import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/ui/call_stage.dart';
import 'package:hubbub/video_options.dart';

void main() {
  // LiveKit's layers for the 1080p constraint: f 1920x1080, h 1280x720, q 640x360.
  FitLayer layer(String rid, double scale, {int? w, int? h, bool active = true}) =>
      FitLayer(rid: rid, scale: scale, active: active, frameWidth: w, frameHeight: h);

  group('ShareFit', () {
    test('a_4k_capture_scales_every_layer_to_base_times_the_factor', () {
      final fit = ShareFit();
      final plan = fit.plan([
        layer('f', 1, w: 3840, h: 2160),
        layer('h', 1.5, w: 2560, h: 1440),
        layer('q', 3, w: 1280, h: 720),
      ]);
      expect(plan, {'f': 2.0, 'h': 3.0, 'q': 6.0});
    });

    test('the_capture_size_comes_from_any_active_layer_so_a_paused_top_layer_does_not_matter', () {
      final fit = ShareFit();
      final plan = fit.plan([
        layer('f', 1, active: false),
        layer('h', 1.5, w: 2560, h: 1440),
        layer('q', 3, active: false),
      ]);
      expect(plan, {'f': 2.0, 'h': 3.0, 'q': 6.0});
    });

    test('a_scaled_layer_reports_its_frame_times_its_scale', () {
      // Only the 360p layer encodes: 960x540 at scale 4 is a 3840x2160 capture.
      final plan = ShareFit().plan([layer('f', 1, active: false), layer('q', 4, w: 960, h: 540)]);
      expect(plan, {'f': 2.0, 'q': 8.0});
    });

    test('nothing_is_planned_until_a_layer_has_produced_a_frame', () {
      final fit = ShareFit();
      expect(fit.plan([layer('f', 1), layer('h', 1.5)]), isNull);
      expect(fit.applied, isFalse);
      expect(fit.plan([layer('f', 1, w: 3840, h: 2160)]), isNotNull, reason: 'retried on a later tick');
    });

    test('a_capture_that_fits_needs_nothing_and_is_done', () {
      final fit = ShareFit();
      expect(fit.plan([layer('f', 1, w: 1920, h: 1080), layer('q', 3, w: 640, h: 360)]), isNull);
      expect(fit.applied, isTrue);
      expect(fit.done, isTrue);
    });

    test('once_applied_it_plans_nothing_even_with_stale_frame_sizes', () {
      final fit = ShareFit();
      expect(fit.plan([layer('f', 1, w: 3840, h: 2160)]), {'f': 2.0});
      fit.markApplied();
      // The encoder still reports the old size while the scale is already 2.
      expect(fit.plan([layer('f', 2, w: 3840, h: 2160)]), isNull);
    });

    test('a_refused_write_retried_with_the_same_stale_data_gives_the_same_absolute_scale', () {
      final fit = ShareFit();
      expect(fit.plan([layer('f', 1, w: 3840, h: 2160), layer('q', 3, w: 1280, h: 720)]), {'f': 2.0, 'q': 6.0});
      fit.failures++;
      // The cached scales were already changed (current 2 and 6), frames unchanged.
      expect(fit.plan([layer('f', 2, w: 3840, h: 2160), layer('q', 6, w: 1280, h: 720)]), {'f': 2.0, 'q': 6.0});
    });

    test('it_gives_up_after_repeated_refusals', () {
      final fit = ShareFit();
      for (var i = 0; i < ShareFit.maxFailures; i++) {
        fit.failures++;
      }
      expect(fit.plan([layer('f', 1, w: 3840, h: 2160)]), isNull);
    });

    test('a_single_unnamed_layer_is_filed_under_the_empty_key', () {
      expect(ShareFit().plan([const FitLayer(scale: 1, frameWidth: 2560, frameHeight: 1440)]),
          {'': closeTo(4 / 3, 1e-9)});
    });

    test('layers_scale_from_the_base_never_from_the_current_value', () {
      expect(scaledLayers([null, 1.5, 3], 2), [2, 3, 6]);
    });
  });

  group('fitLayersFrom', () {
    test('joins_encodings_and_reported_frames_by_rid', () {
      final layers = fitLayersFrom([
        rtc.RTCRtpEncoding(rid: 'f', scaleResolutionDownBy: 1, active: false),
        rtc.RTCRtpEncoding(rid: 'h', scaleResolutionDownBy: 1.5),
      ], const [
        VideoTxLayer(rid: 'h', width: 2560, height: 1440),
      ]);
      expect(layers[0].frameWidth, isNull);
      expect(layers[0].active, isFalse);
      expect(layers[1].frameWidth, 2560);
      expect(layers[1].scale, 1.5);
    });

    test('a_lone_unnamed_encoding_takes_the_lone_reported_layer', () {
      final layers = fitLayersFrom([rtc.RTCRtpEncoding()], const [VideoTxLayer(width: 1280, height: 720)]);
      expect(layers.single.frameWidth, 1280);
    });
  });

  group('quality and receiving rules', () {
    test('only_the_focused_tile_is_high_for_cameras_and_shares_alike', () {
      expect(wantsHighVideo('stream:bbbb', 'stream:bbbb'), isTrue);
      expect(wantsHighVideo('user:bbbb', 'user:bbbb'), isTrue);
      expect(wantsHighVideo('stream:bbbb', 'user:bbbb'), isFalse);
      expect(wantsHighVideo('stream:bbbb', null), isFalse);
    });

    test('video_is_received_only_with_a_showing_window_and_an_on_screen_tile', () {
      expect(receivesVideo(windowVisible: true, tileOnScreen: true), isTrue);
      expect(receivesVideo(windowVisible: false, tileOnScreen: true), isFalse);
      expect(receivesVideo(windowVisible: true, tileOnScreen: false), isFalse);
    });

    test('hiddenTiles_finds_the_tiles_wholly_outside_the_viewport', () {
      Set<int> h(double offset) => hiddenTiles(count: 6, tileWidth: 100, gap: 10, offset: offset, viewport: 250);
      expect(h(0), {3, 4, 5});
      expect(h(110), {0, 4, 5});
      expect(hiddenTiles(count: 3, tileWidth: 100, gap: 10, offset: 0, viewport: 400), isEmpty);
      expect(hiddenTiles(count: 3, tileWidth: 100, gap: 10, offset: 0, viewport: 0), isEmpty);
    });
  });

  group('pruning', () {
    test('pruneKeys_drops_what_is_no_longer_live', () {
      final m = {'a': 1, 'b': 2, 'c': 3};
      pruneKeys(m, {'b'});
      expect(m, {'b': 2});
    });

    test('pruneVideoStats_drops_both_key_forms_and_stopped_sends', () {
      final rx = {
        'bbbb': const VideoRxSample(participantId: 'bbbb'),
        'bbbb/camera': const VideoRxSample(participantId: 'bbbb', source: 'camera'),
        'cccc/camera': const VideoRxSample(participantId: 'cccc', source: 'camera'),
      };
      final tx = {'screen': const VideoTxSample(), 'camera': const VideoTxSample(source: 'camera')};
      pruneVideoStats(rx, tx, sharing: false, cameraOn: true, cameraFrom: {'cccc'}, shareFrom: {});
      expect(rx.keys, ['cccc/camera']);
      expect(tx.keys, ['camera']);
    });
  });

  group('videoTxFromReports', () {
    rtc.StatsReport out(String id, Map<String, Object?> v) =>
        rtc.StatsReport(id, 'outbound-rtp', 0, {'kind': 'video', ...v});

    test('a_missing_rtt_is_null_and_formats_as_a_dash', () {
      final s = videoTxFromReports('screen', [out('o', {'rid': 'f'})], {}, nowMs: 1);
      expect(s.rttMs, isNull);
      expect(formatVideoTx(s), contains('rtt=-'));
    });

    test('the_rtt_is_the_transports_selected_pair_not_the_last_succeeded_one', () {
      final s = videoTxFromReports('screen', [
        rtc.StatsReport('t', 'transport', 0, {'selectedCandidatePairId': 'p1'}),
        rtc.StatsReport('p1', 'candidate-pair', 0, {'state': 'succeeded', 'currentRoundTripTime': 0.004}),
        rtc.StatsReport('p2', 'candidate-pair', 0, {'state': 'succeeded', 'currentRoundTripTime': 0.250}),
      ], {}, nowMs: 1);
      expect(s.rttMs, closeTo(4, 1e-9));
    });

    test('without_a_transport_the_pair_marked_selected_is_used_and_an_ambiguous_set_gives_none', () {
      final selected = videoTxFromReports('screen', [
        rtc.StatsReport('p1', 'candidate-pair', 0, {'currentRoundTripTime': 0.004}),
        rtc.StatsReport('p2', 'candidate-pair', 0, {'selected': true, 'currentRoundTripTime': 0.009}),
      ], {}, nowMs: 1);
      expect(selected.rttMs, closeTo(9, 1e-9));
      final ambiguous = videoTxFromReports('screen', [
        rtc.StatsReport('p1', 'candidate-pair', 0, {'nominated': true, 'state': 'succeeded', 'currentRoundTripTime': 0.004}),
        rtc.StatsReport('p2', 'candidate-pair', 0, {'nominated': true, 'state': 'succeeded', 'currentRoundTripTime': 0.009}),
      ], {}, nowMs: 1);
      expect(ambiguous.rttMs, isNull);
    });

    test('a_non_string_rid_or_field_does_not_throw_the_tick_away', () {
      final s = videoTxFromReports('screen', [
        out('o1', {'rid': 7, 'qualityLimitationReason': 3, 'encoderImplementation': false, 'frameWidth': 640}),
        out('o2', {'rid': 'q', 'frameWidth': '320'}),
      ], {}, nowMs: 1);
      expect(s.layers.length, 2);
      expect(s.layers[0].rid, isNull);
      expect(s.layers[0].width, 640);
      expect(s.layers[1].width, 320);
    });

    test('seen_collects_the_outbound_ids_so_the_counters_can_be_pruned', () {
      final prev = <String, (num, num)>{'gone': (1, 1)};
      final seen = <String>{};
      videoTxFromReports('screen', [out('o1', {'bytesSent': 10})], prev, nowMs: 5, seen: seen);
      pruneKeys(prev, seen);
      expect(prev.keys, ['o1']);
    });
  });
}
