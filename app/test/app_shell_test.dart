import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/app_shell.dart';
import 'package:hubbub/hub_controller.dart';

import 'support/fakes.dart';

/// Lets the (async) handlers finish.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Same, when the handler touches a real file.
Future<void> settleIo() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  late FakeHub api;
  late HubController hub;
  late FakeAppShell shell;
  late HideNoticeStore notice;
  var notices = 0;

  Future<TrayLifecycle> lifecycle({bool tray = true}) async {
    shell = FakeAppShell(hasTray: tray);
    final l = TrayLifecycle(
      shell: shell,
      shutdown: hub.shutdown,
      notice: notice,
      showNotice: () async => notices++,
    );
    await l.start();
    return l;
  }

  setUp(() {
    api = FakeHub();
    hub = HubController(api)..refresh();
    notice = HideNoticeStore.memory();
    notices = 0;
  });

  group('closing the window', () {
    test('with a tray hides the window and leaves the hub running', () async {
      await lifecycle();
      shell.closeWindow();
      await settle();
      expect(shell.visible, isFalse);
      expect(shell.calls, ['start', 'hide']);
      expect(api.calls, isNot(contains('shutdown')));
    });

    test('without a tray shuts the hub down, then exits', () async {
      await lifecycle(tray: false);
      shell.closeWindow();
      await settle();
      expect(api.calls, ['shutdown']);
      expect(shell.calls, ['start', 'exit']);
    });
  });

  group('tray menu', () {
    test('Quit shuts down once, then exits; a second Quit does not shut down twice', () async {
      await lifecycle();
      shell.trayQuit();
      shell.trayQuit();
      await settle();
      expect(api.calls.where((c) => c == 'shutdown'), hasLength(1));
      expect(shell.calls.where((c) => c == 'exit'), hasLength(1));
      expect(shell.calls.indexOf('exit'), greaterThan(-1));
    });

    test('Quit exits even when shutdown fails', () async {
      shell = FakeAppShell();
      final l = TrayLifecycle(
          shell: shell, shutdown: () async => throw StateError('boom'), notice: notice);
      await l.start();
      shell.trayQuit();
      await settle();
      expect(shell.calls, contains('exit'));
    });

    test('Open shows the window again', () async {
      await lifecycle();
      shell.closeWindow();
      await settle();
      shell.trayOpen();
      await settle();
      expect(shell.visible, isTrue);
      expect(shell.calls, ['start', 'hide', 'show']);
    });
  });

  group('a link while hidden', () {
    test('shows the window and still reaches the Join flow', () async {
      await lifecycle();
      await shell.hideWindow();
      expect(shell.visible, isFalse);
      final links = FakeLinks();
      final source = WindowRevealingLinks(links, shell);
      final got = <String>[];
      source.stream.listen(got.add);
      links.send('hubbub://join/abc');
      await settle();
      expect(shell.visible, isTrue);
      expect(got, ['hubbub://join/abc']);
    });
  });

  group('first hide notice', () {
    test('shows once, before the window hides', () async {
      await lifecycle();
      shell.closeWindow();
      await settle();
      shell.trayOpen();
      shell.closeWindow();
      await settle();
      expect(notices, 1);
      expect(shell.calls.where((c) => c == 'hide'), hasLength(2));
    });

    test('is not shown again after a restart', () async {
      final dir = Directory.systemTemp.createTempSync('hubbub_notice');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}tray.json';
      notice = HideNoticeStore.file(path);
      await lifecycle();
      shell.closeWindow();
      await settleIo();
      expect(notices, 1);

      notice = HideNoticeStore.file(path); // a new run of the app
      await lifecycle();
      shell.closeWindow();
      await settleIo();
      expect(notices, 1);
    });

    test('is not shown when the window quits instead of hiding', () async {
      await lifecycle(tray: false);
      shell.closeWindow();
      await settle();
      expect(notices, 0);
    });
  });
}
