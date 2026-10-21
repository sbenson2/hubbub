import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/overlay/game_overlay.dart';
import 'package:hubbub/overlay/game_rules.dart';
import 'package:hubbub/overlay/overlay_prefs.dart';
import 'package:hubbub/overlay/overlay_scene.dart';
import 'package:hubbub/ui/channel_sidebar.dart';

import 'support/fake_overlay.dart';

const mon = Rectangle<int>(0, 0, 1920, 1080);

ForegroundFacts game({int hwnd = 1, int dpi = 96, Rectangle<int> client = mon}) => ForegroundFacts(
      hwnd: hwnd,
      path: r'C:\Games\Foo\Foo.exe',
      own: false,
      windowClass: 'UnityWndClass',
      caption: false,
      window: mon,
      client: client,
      monitor: mon,
      minimized: false,
      dpi: dpi,
    );

ForegroundFacts windowed(String path, Rectangle<int> client) => ForegroundFacts(
      hwnd: 7,
      path: path,
      own: false,
      windowClass: 'GameWindow',
      caption: true,
      window: client,
      client: client,
      monitor: mon,
      minimized: false,
      dpi: 96,
    );

ForegroundFacts desktop() => const ForegroundFacts(
      hwnd: 3,
      path: r'C:\Windows\explorer.exe',
      own: false,
      windowClass: 'WorkerW',
      caption: false,
      window: mon,
      client: mon,
      monitor: mon,
      minimized: false,
      dpi: 96,
    );

VoiceMember me({bool speaking = false, bool muted = false}) =>
    VoiceMember(id: 'me', name: 'Shawn', isMe: true, speaking: speaking, muted: muted);

void main() {
  late FakeOverlayHost host;
  late OverlaySettings settings;
  late DateTime now;
  late GameOverlayController controller;

  setUp(() {
    host = FakeOverlayHost();
    settings = OverlaySettings(OverlayPrefsStore.memory());
    now = DateTime(2026, 10, 20, 12);
    controller = GameOverlayController(host: host, settings: settings, clock: () => now);
  });

  Future<void> inCall(List<VoiceMember> members) async {
    controller.setCall(members);
    await pumpEventQueue();
  }

  Future<void> see(ForegroundFacts? f) async {
    host.emit(f);
    await pumpEventQueue();
  }

  test('nothing_starts_outside_a_call', () async {
    controller.setCall(null);
    await see(game());
    expect(host.calls, isEmpty);
  });

  test('a_call_starts_the_watcher_and_reads_the_game_list', () async {
    await inCall([me()]);
    expect(host.calls, ['start', 'knownGames']);
  });

  test('a_fullscreen_game_shows_the_rows_at_its_corner', () async {
    await inCall([me()]);
    await see(game());
    expect(host.calls.last, 'show 16,16');
    expect(
        host.scenes.last,
        const OverlayScene(
          rows: [
            OverlayRow(
                id: 'me',
                name: 'Shawn',
                speaking: false,
                muted: false,
                deafened: false,
                showName: true),
          ],
          avatarSize: OverlayAvatarSize.large,
          pixelRatio: 1.0,
        ));
  });

  test('leaving_the_game_hides_and_returning_moves_without_redrawing', () async {
    await inCall([me()]);
    await see(game());
    final drawn = host.scenes.length;
    await see(desktop());
    expect(host.calls.last, 'hide');
    await see(game());
    expect(host.calls.last, 'move 16,16');
    expect(host.scenes.length, drawn);
  });

  test('only_a_visible_change_redraws', () async {
    await inCall([me()]);
    await see(game());
    final calls = host.calls.length;
    await inCall([me()]); // an equal list in a new instance
    expect(host.calls.length, calls);
    await inCall([me(speaking: true)]);
    expect(host.calls.length, calls + 1);
    expect(host.calls.last, 'show 16,16');
    expect(host.scenes.length, 2);
  });

  test('a_window_move_only_moves', () async {
    host.games = {r'c:\new\game.exe'};
    await inCall([me()]);
    await see(windowed(r'C:\New\Game.exe', const Rectangle(100, 100, 1280, 720)));
    expect(host.calls.last, 'show 116,116');
    await see(windowed(r'C:\New\Game.exe', const Rectangle(300, 200, 1280, 720)));
    expect(host.calls.last, 'move 316,216');
    expect(host.scenes.length, 1);
  });

  test('a_dpi_change_redraws_at_the_new_ratio', () async {
    await inCall([me()]);
    await see(game());
    await see(game(dpi: 144));
    expect(host.calls.last, 'show 24,24');
    expect(host.scenes.last.pixelRatio, 1.5);
  });

  test('switching_between_two_games_reasserts_the_window', () async {
    await inCall([me()]);
    await see(game(hwnd: 1));
    await see(game(hwnd: 2));
    expect(host.calls.last, 'move 16,16');
    expect(host.scenes.length, 1);
  });

  test('leaving_the_call_stops_the_watcher', () async {
    await inCall([me()]);
    await see(game());
    controller.setCall(null);
    await pumpEventQueue();
    expect(host.calls.last, 'stop');
    expect(host.calls.where((c) => c == 'hide'), isEmpty); // stop hides it
  });

  test('the_setting_applies_live', () async {
    await inCall([me()]);
    await settings.update(settings.prefs.copyWith(enabled: false));
    await pumpEventQueue();
    expect(host.calls.last, 'stop');
    await settings.update(settings.prefs.copyWith(enabled: true));
    await pumpEventQueue();
    expect(host.calls.sublist(host.calls.length - 2), ['start', 'knownGames']);
    await see(game());
    expect(host.calls.last, 'show 16,16');
  });

  test('a_settings_change_redraws', () async {
    await inCall([me()]);
    await see(game());
    await settings.update(settings.prefs.copyWith(avatarSize: OverlayAvatarSize.small));
    await pumpEventQueue();
    expect(host.scenes.last.avatarSize, OverlayAvatarSize.small);
    expect(host.scenes.length, 2);
  });

  test('nobody_to_show_hides_instead_of_drawing', () async {
    await settings.update(settings.prefs.copyWith(users: OverlayUsers.whileSpeaking));
    await inCall([me(speaking: true)]);
    await see(game());
    expect(host.calls.last, 'show 16,16');
    await inCall([me()]);
    expect(host.calls.last, 'hide');
    expect(host.scenes.length, 1);
    expect(host.scenes.every((s) => s.rows.isNotEmpty), isTrue);
  });

  test('changes_during_a_draw_collapse_to_the_latest', () async {
    await inCall([]);
    await see(game());
    host.showGate = Completer<void>();
    await inCall([me(speaking: true)]);
    expect(host.calls.last, 'show 16,16'); // in flight
    await inCall([me()]);
    await inCall([me(speaking: true)]);
    await inCall([me(speaking: true, muted: true)]);
    host.showGate!.complete();
    await pumpEventQueue();
    expect(host.calls.where((c) => c.startsWith('show')).length, 2);
    final row = host.scenes.last.rows.single;
    expect(row.speaking, isTrue);
    expect(row.muted, isTrue);
  });

  test('a_hide_waits_for_the_draw_in_flight_and_lands_after_it', () async {
    await inCall([me()]);
    host.showGate = Completer<void>();
    await see(game());
    expect(host.calls.last, 'show 16,16');
    await see(desktop());
    expect(host.calls.last, 'show 16,16'); // not sent while the draw is awaiting
    host.showGate!.complete();
    await pumpEventQueue();
    expect(host.calls.sublist(host.calls.length - 2), ['show 16,16', 'hide']);
  });

  test('leaving_the_call_during_a_draw_stops_after_it_and_sends_no_hide', () async {
    await inCall([me()]);
    host.showGate = Completer<void>();
    await see(game());
    controller.setCall(null);
    await pumpEventQueue();
    expect(host.calls.last, 'show 16,16');
    host.showGate!.complete();
    await pumpEventQueue();
    expect(host.calls.sublist(host.calls.length - 2), ['show 16,16', 'stop']);
    expect(host.calls.where((c) => c == 'hide'), isEmpty);
    // Facts from before the stop don't survive it.
    host.emit(game());
    await pumpEventQueue();
    expect(host.calls.last, 'stop');
  });

  test('a_failed_draw_is_retried_on_the_next_change', () async {
    await inCall([me()]);
    host.failNextShow = true;
    await see(game());
    expect(host.calls.last, 'show 16,16');
    await inCall([me(speaking: true)]);
    expect(host.calls.where((c) => c.startsWith('show')).length, 2);
    expect(host.scenes.last.rows.single.speaking, isTrue);
  });

  test('a_failed_draw_does_not_stop_the_overlay_for_good', () async {
    await inCall([me()]);
    host.failNextShow = true;
    await see(game());
    await see(game(client: const Rectangle(0, 0, 1900, 1000))); // same scene, same origin
    expect(host.calls.where((c) => c == 'stop'), isEmpty);
    expect(host.calls.where((c) => c.startsWith('show')).length, 2);
  });

  test('an_unknown_windowed_exe_is_rechecked_after_30_s', () async {
    const path = r'C:\New\Game.exe';
    await inCall([me()]);
    await see(windowed(path, const Rectangle(100, 100, 1280, 720)));
    expect(host.calls.where((c) => c.startsWith('show')), isEmpty);
    host.games = {r'c:\new\game.exe'};
    now = now.add(const Duration(seconds: 10));
    final before = host.calls.where((c) => c == 'knownGames').length;
    await see(windowed(path, const Rectangle(110, 100, 1280, 720)));
    expect(host.calls.where((c) => c == 'knownGames').length, before);
    now = now.add(const Duration(seconds: 21));
    await see(windowed(path, const Rectangle(120, 100, 1280, 720)));
    expect(host.calls.where((c) => c == 'knownGames').length, before + 1);
    expect(host.calls.last, 'show 136,116');
  });

  test('equal_facts_are_ignored', () async {
    await inCall([me()]);
    await see(game());
    final calls = host.calls.length;
    await see(game());
    expect(host.calls.length, calls);
  });

  test('foreground_facts_compare_by_value', () {
    expect(game(), game());
    expect(game().hashCode, game().hashCode);
    expect(game(), isNot(game(hwnd: 2)));
    expect(game(), isNot(game(dpi: 144)));
    expect(game(), isNot(game(client: const Rectangle(1, 0, 1919, 1080))));
  });
}
