import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/app_shell.dart';
import 'package:hubbub/audio_settings.dart';
import 'package:hubbub/device_settings.dart';
import 'package:hubbub/hub_controller.dart';
import 'package:hubbub/install.dart';
import 'package:hubbub/ui/dialogs/update_banner.dart';
import 'package:hubbub/ui/settings_dialog.dart';
import 'package:hubbub/ui/theme.dart';

import 'support/fakes.dart';

/// Scripts what the feed holds and records what the updater was asked.
class FakeUpdateService implements UpdateService {
  String? available;
  String? waiting;
  bool offline = false;
  final calls = <String>[];

  @override
  Future<String?> check(String feed) async {
    calls.add('check $feed');
    if (offline) throw Exception('no network');
    return available;
  }

  @override
  Future<String> download(String feed) async {
    calls.add('download');
    waiting = available;
    return available!;
  }

  @override
  String? pending() => waiting;

  @override
  void applyOnExit({required bool restart}) => calls.add('apply restart=$restart');
}

/// Records the toggle; stands in for the HKCU Run value.
class FakeWindowsSettings implements WindowsSettings {
  FakeWindowsSettings({this.startAtLogin = true, this.version = '0.1.0', this.failWrites = false});

  @override
  bool startAtLogin;
  @override
  final String? version;
  final writes = <bool>[];
  final bool failWrites;

  @override
  void setStartAtLogin(bool on) {
    if (failWrites) throw Exception('registry says no');
    writes.add(on);
    startAtLogin = on;
  }
}

const feed = 'https://example.test/releases';

void main() {
  group('updaterSupported', () {
    test('only an installed Windows copy updates itself', () {
      expect(updaterSupported(isWindows: true, installedVersion: '0.1.0'), isTrue);
      expect(updaterSupported(isWindows: true, installedVersion: null), isFalse);
      // Linux updates are manual for now, even from an AppImage that reports a version.
      expect(updaterSupported(isWindows: false, installedVersion: '0.1.0'), isFalse);
    });
  });

  group('resolveUpdateFeed', () {
    test('the placeholder means no feed yet', () {
      expect(resolveUpdateFeed(env: {}), isNull);
      expect(resolveUpdateFeed(compiled: 'https://github.com/<OWNER>/r/releases/latest/download', env: {}), isNull);
    });

    test('a real URL is used, and the environment overrides it', () {
      expect(resolveUpdateFeed(compiled: feed, env: {}), feed);
      expect(resolveUpdateFeed(compiled: feed, env: {'HUBBUB_UPDATE_FEED': r'C:\feed'}), r'C:\feed');
    });
  });

  group('UpdateController', () {
    late FakeUpdateService service;
    late UpdateController updates;

    setUp(() {
      service = FakeUpdateService();
      updates = UpdateController(service: service, feed: feed);
    });
    tearDown(() => updates.dispose());

    test('a newer release is downloaded in the background and then ready', () async {
      service.available = '0.2.0';
      final seen = <UpdatePhase>[];
      updates.addListener(() => seen.add(updates.phase));
      await updates.check();
      expect(seen, [UpdatePhase.checking, UpdatePhase.downloading, UpdatePhase.ready]);
      expect(updates.version, '0.2.0');
      expect(service.calls, ['check $feed', 'download']);
    });

    test('nothing newer leaves it idle', () async {
      await updates.check();
      expect(updates.phase, UpdatePhase.idle);
      expect(updates.ready, isFalse);
    });

    test('an unreachable feed is silent and tried again later', () async {
      service.offline = true;
      final printed = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {}; // the silent failure is logged
      addTearDown(() => debugPrint = printed);
      await updates.check();
      expect(updates.phase, UpdatePhase.idle);
      service.offline = false;
      service.available = '0.2.0';
      await updates.check();
      expect(updates.ready, isTrue);
    });

    test('a feed that is not configured is never contacted', () async {
      final none = UpdateController(service: service, feed: null);
      addTearDown(none.dispose);
      await none.check();
      expect(service.calls, isEmpty);
    });

    test('an update downloaded in an earlier run is ready at once', () {
      service.waiting = '0.2.0';
      final again = UpdateController(service: service, feed: feed);
      addTearDown(again.dispose);
      expect(again.ready, isTrue);
      expect(again.version, '0.2.0');
    });

    test('no restart during a call; allowed once the call ends', () async {
      service.available = '0.2.0';
      var quits = 0;
      updates.quit = () async => quits++;
      await updates.check();
      updates.callActive.value = true;
      expect(updates.canRestartNow, isFalse);
      expect(await updates.restart(), isFalse);
      expect(quits, 0);
      expect(service.calls, isNot(contains(startsWith('apply'))));
      updates.callActive.value = false;
      expect(updates.canRestartNow, isTrue);
      expect(await updates.restart(), isTrue);
      expect(quits, 1);
    });

    test('a quit applies a ready update without restarting; Restart applies it and restarts', () async {
      service.available = '0.2.0';
      await updates.check();
      updates.applyBeforeExit();
      expect(service.calls.last, 'apply restart=false');

      updates.quit = () async => updates.applyBeforeExit(); // what TrayLifecycle.quit does
      await updates.restart();
      expect(service.calls.last, 'apply restart=true');
    });

    test('a quit with nothing ready does not call the updater', () {
      updates.applyBeforeExit();
      expect(service.calls, isEmpty);
    });

    testWidgets('checks at start and every 6 hours', (tester) async {
      updates.start();
      await tester.pump();
      expect(service.calls, ['check $feed']);
      await tester.pump(const Duration(hours: 6));
      expect(service.calls, ['check $feed', 'check $feed']);
      await tester.pump(const Duration(hours: 6));
      expect(service.calls.length, 3);
      updates.dispose();
      updates = UpdateController(service: service, feed: feed);
    });
  });

  group('the quit path', () {
    test('hands a ready update over after the hub has shut down, before the process exits', () async {
      final api = FakeHub();
      final hub = HubController(api)..refresh();
      final shell = FakeAppShell(hasTray: true);
      final service = FakeUpdateService()..available = '0.2.0';
      final updates = UpdateController(service: service, feed: feed);
      addTearDown(updates.dispose);
      await updates.check();
      final lifecycle = TrayLifecycle(
        shell: shell,
        shutdown: hub.shutdown,
        notice: HideNoticeStore.memory(true),
        beforeExit: () {
          api.calls.add('apply');
          updates.applyBeforeExit();
        },
      );
      await lifecycle.start();
      await lifecycle.quit();
      expect(api.calls, ['shutdown', 'apply']);
      expect(service.calls.last, 'apply restart=false');
      expect(shell.calls.last, 'exit');
    });
  });

  group('UpdateBanner', () {
    Future<UpdateController> pump(WidgetTester tester) async {
      final service = FakeUpdateService()..available = '0.2.0';
      final updates = UpdateController(service: service, feed: feed);
      addTearDown(updates.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: hubbubTheme(), home: Scaffold(body: Column(children: [UpdateBanner(updates: updates)]))));
      await updates.check();
      await tester.pump();
      return updates;
    }

    testWidgets('shows Restart once ready, and hides the button during a call', (tester) async {
      final updates = await pump(tester);
      expect(find.textContaining('Update ready'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
      updates.callActive.value = true;
      await tester.pump();
      expect(find.text('Restart'), findsNothing);
      expect(find.textContaining('after your call'), findsOneWidget);
    });

    testWidgets('shows nothing before an update is ready', (tester) async {
      final updates = UpdateController(service: FakeUpdateService(), feed: feed);
      addTearDown(updates.dispose);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: UpdateBanner(updates: updates))));
      expect(find.textContaining('Update'), findsNothing);
    });
  });

  group('Windows Settings', () {
    Future<FakeWindowsSettings> open(WidgetTester tester, {bool startAtLogin = true, bool failWrites = false}) async {
      final windows = FakeWindowsSettings(startAtLogin: startAtLogin, failWrites: failWrites);
      final room = FakeRoom();
      await tester.pumpWidget(MaterialApp(
        theme: hubbubTheme(),
        home: Scaffold(body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context,
                memberId: 'a' * 64,
                tag: 'AAAA',
                devices: DeviceSettings(room, DevicePrefsStore.memory()),
                audio: AudioSettings(room, AudioPrefsStore.memory()),
                inCall: ValueNotifier(false),
                windows: windows),
            child: const Text('open'),
          ),
        )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Windows Settings'));
      await tester.pumpAndSettle();
      return windows;
    }

    testWidgets('the toggle writes and removes the login entry', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final windows = await open(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('start-at-login'))).value, isTrue);
      await tester.tap(find.byKey(const Key('start-at-login')));
      await tester.pumpAndSettle();
      expect(windows.writes, [false]);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('start-at-login'))).value, isFalse);
      await tester.tap(find.byKey(const Key('start-at-login')));
      await tester.pumpAndSettle();
      expect(windows.writes, [false, true]);
      expect(find.text('Hubbub 0.1.0'), findsOneWidget);
    });

    testWidgets('a failed write puts the switch back and says so', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, failWrites: true);
      await tester.tap(find.byKey(const Key('start-at-login')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('start-at-login'))).value, isTrue);
      expect(find.text('Could not change that setting.'), findsOneWidget);
    });
  });
}
