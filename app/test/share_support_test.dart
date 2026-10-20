import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/share_sources.dart';
import 'package:hubbub/video_options.dart';

void main() {
  const wayland = {'XDG_SESSION_TYPE': 'wayland', 'WAYLAND_DISPLAY': 'wayland-0'};

  test('a_wayland_session_on_linux_shares_through_the_system_portal', () {
    expect(portalScreenShare(isLinux: true, env: wayland), isTrue);
    expect(screenShareSupported(isLinux: true, env: wayland), isTrue);
  });

  test('half_a_wayland_session_is_refused_because_libwebrtc_would_pick_x11_and_get_black', () {
    for (final env in [
      {'XDG_SESSION_TYPE': 'wayland'},
      {'XDG_SESSION_TYPE': 'wayland', 'WAYLAND_DISPLAY': ''},
      {'WAYLAND_DISPLAY': 'wayland-0'},
      {'XDG_SESSION_TYPE': 'x11', 'WAYLAND_DISPLAY': 'wayland-0'},
    ]) {
      expect(portalScreenShare(isLinux: true, env: env), isFalse, reason: '$env');
      expect(screenShareSupported(isLinux: true, env: env), isFalse, reason: '$env');
    }
  });

  test('x11_and_other_platforms_never_use_the_portal', () {
    expect(portalScreenShare(isLinux: true, env: {'XDG_SESSION_TYPE': 'x11'}), isFalse);
    expect(portalScreenShare(isLinux: true, env: const {}), isFalse);
    expect(portalScreenShare(isLinux: false, env: wayland), isFalse);
  });

  test('x11_linux_and_other_platforms_can', () {
    expect(screenShareSupported(isLinux: true, env: {'XDG_SESSION_TYPE': 'x11'}), isTrue);
    expect(screenShareSupported(isLinux: true, env: const {}), isTrue);
    expect(screenShareSupported(isLinux: false, env: {'XDG_SESSION_TYPE': 'wayland'}), isTrue);
  });

  test('only_linux_shares_picture_alone', () {
    expect(shareAudioSupported(isLinux: true), isFalse);
    expect(shareAudioSupported(isLinux: false), isTrue);
  });

  group('the share watch', () {
    var clock = DateTime(2026, 1, 1);
    var listings = 0;
    var sources = <ShareSource>[];
    late ScreenSourceCheck check;
    setUp(() {
      clock = DateTime(2026, 1, 1);
      listings = 0;
      sources = const [
        ShareSource(id: 's1', name: 'Screen 1', kind: ShareKind.screen),
        ShareSource(id: 'w1', name: 'Window', kind: ShareKind.window),
      ];
      check = ScreenSourceCheck(
        list: () async {
          listings++;
          return sources;
        },
        now: () => clock,
      );
    });

    test('a_screen_is_listed_once_and_then_believed_until_the_recheck', () async {
      expect(await check.exists('s1'), isTrue);
      for (var i = 0; i < 9; i++) {
        clock = clock.add(const Duration(seconds: 3));
        expect(await check.exists('s1'), isTrue);
      }
      expect(listings, 1, reason: 'ten 3 s ticks must not list every screen ten times');
    });

    test('a_removed_screen_is_noticed_at_the_recheck', () async {
      expect(await check.exists('s1'), isTrue);
      sources = const [];
      clock = clock.add(ScreenSourceCheck.screenRecheck);
      expect(await check.exists('s1'), isFalse);
      expect(listings, 2);
    });

    test('a_window_is_listed_every_time_without_a_cheap_test', () async {
      expect(await check.exists('w1'), isTrue);
      expect(await check.exists('w1'), isTrue);
      expect(listings, 2);
    });

    test('a_live_window_passes_the_cheap_test_without_listing', () async {
      final windows = ScreenSourceCheck(
        list: () async {
          listings++;
          return sources;
        },
        isWindow: (id) => id == 'w1',
      );
      expect(await windows.exists('w1'), isTrue);
      expect(listings, 0);
    });
  });
}
