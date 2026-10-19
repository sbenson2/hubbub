// Runs on the Windows desktop:
//   flutter test integration_test/share_window_test.dart -d windows
// A window share ends when its window is gone (HomePage._watchShare). Minimizing the window
// must not count as gone (ruling R40); closing it must. The capturer leaves out this process's
// own windows, so the test opens a throwaway PowerShell form with a known title.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hubbub/share_sources.dart';
import 'package:integration_test/integration_test.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _isWindow = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
final _isIconic = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final _showWindow =
    _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final _postMessage = _user32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('PostMessageW');

const _title = 'hubbub-share-probe';
const _swMinimize = 6;
const _swRestore = 9;
const _wmClose = 0x0010;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a minimized window still exists for the share check; a closed one does not',
      (tester) async {
    final form = await Process.start('powershell.exe', [
      '-NoProfile',
      '-Command',
      "Add-Type -AssemblyName System.Windows.Forms; \$f = New-Object Windows.Forms.Form; "
          "\$f.Text = '$_title'; [void]\$f.ShowDialog()",
    ]);
    addTearDown(form.kill);

    Future<String?> probeId() async {
      final all = await desktopCapturer.getSources(types: [SourceType.Window]);
      for (final s in all) {
        if (s.name == _title) return s.id;
      }
      return null;
    }

    String? id;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (id == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      id = await probeId();
    }
    expect(id, isNotNull, reason: 'the probe window should appear in the window list');
    final hwnd = int.parse(id!);
    expect(_isWindow(hwnd), isNot(0), reason: 'a window source id is its HWND');
    expect(await desktopSourceExists(id), isTrue);

    _showWindow(hwnd, _swMinimize);
    await Future<void>.delayed(const Duration(seconds: 1));
    final listed = await probeId() == id;
    final minimizedExists = await desktopSourceExists(id);
    // ignore: avoid_print
    print('hubbub-it: minimized IsIconic=${_isIconic(hwnd)} listed=$listed '
        'desktopSourceExists=$minimizedExists');
    expect(minimizedExists, isTrue, reason: 'a minimized window is not a closed one');

    _showWindow(hwnd, _swRestore);
    _postMessage(hwnd, _wmClose, 0, 0);
    await form.exitCode.timeout(const Duration(seconds: 10));
    expect(await desktopSourceExists(id), isFalse, reason: 'the window was closed');
  });
}
