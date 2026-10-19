import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/video_options.dart';

void main() {
  test('wayland_sessions_on_linux_cannot_share_a_screen', () {
    expect(screenShareSupported(isLinux: true, env: {'XDG_SESSION_TYPE': 'wayland'}), isFalse);
    expect(screenShareSupported(isLinux: true, env: {'WAYLAND_DISPLAY': 'wayland-0'}), isFalse);
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
