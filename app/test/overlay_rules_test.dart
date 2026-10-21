import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/overlay/game_rules.dart';

const mon = Rectangle<int>(0, 0, 1920, 1080);

ForegroundFacts f({
  String path = r'C:\Games\Foo\Foo.exe',
  String cls = 'UnityWndClass',
  bool caption = false,
  Rectangle<int> window = mon,
  Rectangle<int> client = mon,
  bool own = false,
  bool minimized = false,
  int dpi = 96,
  int hwnd = 1,
}) =>
    ForegroundFacts(
      hwnd: hwnd,
      path: path,
      own: own,
      windowClass: cls,
      caption: caption,
      window: window,
      client: client,
      monitor: mon,
      minimized: minimized,
      dpi: dpi,
    );

void main() {
  test('no_foreground_is_not_a_game', () {
    expect(isGameInFront(null, {}), isFalse);
  });
  test('hubbub_itself_never_counts', () {
    expect(isGameInFront(f(own: true), {}), isFalse);
  });
  test('a_minimized_window_never_counts', () {
    expect(isGameInFront(f(minimized: true), {}), isFalse);
  });
  test('a_fullscreen_unknown_exe_counts', () {
    expect(isGameInFront(f(), {}), isTrue);
  });
  test('a_borderless_window_overhanging_the_monitor_counts', () {
    expect(
        isGameInFront(f(window: const Rectangle(-1, -1, 1922, 1082)), {}),
        isTrue);
  });
  test('a_known_game_in_a_window_counts_case_insensitively', () {
    const w = Rectangle<int>(100, 100, 1280, 720);
    final g = f(window: w, client: w, caption: true);
    expect(isGameInFront(g, {r'c:\games\foo\foo.exe'}), isTrue);
    expect(isGameInFront(g, {}), isFalse);
  });
  test('a_maximized_window_short_of_the_taskbar_is_not_fullscreen', () {
    expect(
        isGameInFront(
            f(window: const Rectangle(0, 0, 1920, 1032), caption: true), {}),
        isFalse);
  });
  test('a_captioned_window_covering_the_monitor_is_not_fullscreen', () {
    expect(isGameInFront(f(caption: true, window: mon), {}), isFalse);
  });
  test('browsers_players_slideshows_remote_and_calls_hide', () {
    for (final exe in [
      'chrome.exe',
      'vlc.exe',
      'POWERPNT.EXE',
      'mstsc.exe',
      'Zoom.exe'
    ]) {
      expect(isGameInFront(f(path: 'C:\\Apps\\$exe'), {}), isFalse, reason: exe);
    }
  });
  test('an_excluded_app_in_the_game_list_still_hides', () {
    const p = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    expect(isGameInFront(f(path: p), {normalizeExePath(p)}), isFalse);
  });
  test('the_desktop_hides', () {
    expect(
        isGameInFront(f(path: r'C:\Windows\explorer.exe', cls: 'WorkerW'), {}),
        isFalse);
  });
  test('a_screensaver_hides', () {
    expect(isGameInFront(f(path: r'C:\Windows\System32\Mystify.scr'), {}),
        isFalse);
  });
  test('an_unreadable_path_still_uses_the_fullscreen_rule', () {
    expect(isGameInFront(f(path: ''), {}), isTrue);
  });
  test('an_unreadable_path_with_a_shell_class_hides', () {
    expect(isGameInFront(f(path: '', cls: 'Progman'), {}), isFalse);
  });
  test('the_origin_is_the_client_corner_plus_the_scaled_margin', () {
    expect(
        overlayOrigin(
            f(client: const Rectangle(100, 200, 800, 600), dpi: 144)),
        const Point(124, 224));
  });
  test('the_origin_stays_on_the_monitor', () {
    expect(overlayOrigin(f(client: const Rectangle(-50, -30, 800, 600))),
        const Point(16, 16));
  });
  test('facts_parse_from_the_native_map', () {
    Map<String, Object?> map() => {
          'hwnd': 1,
          'path': r'C:\Games\Foo\Foo.exe',
          'own': false,
          'cls': 'UnityWndClass',
          'caption': false,
          'window': [0, 0, 1920, 1080],
          'client': [0, 0, 1920, 1080],
          'monitor': [0, 0, 1920, 1080],
          'minimized': false,
          'dpi': 144,
        };
    final facts = ForegroundFacts.fromMap(map())!;
    expect(facts.window, mon);
    expect(facts.exeName, 'foo.exe');
    expect(facts.dpi, 144);
    expect(ForegroundFacts.fromMap(null), isNull);
    expect(ForegroundFacts.fromMap(map()..remove('dpi')), isNull);
    expect(ForegroundFacts.fromMap(map()..['window'] = [0, 0, 1920]), isNull);
  });
}
