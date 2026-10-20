import 'package:flutter_test/flutter_test.dart';
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
}
