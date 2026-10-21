import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_shell.dart';
import 'audio_settings.dart';
import 'device_settings.dart';
import 'frb_hub.dart';
import 'hub_controller.dart';
import 'install.dart';
import 'links.dart';
import 'node_controller.dart';
import 'overlay/game_overlay.dart';
import 'plugin_shell.dart';
import 'room_adapter.dart';
import 'src/rust/api/hubbub.dart';
import 'src/rust/api/install.dart' as install;
import 'ui/home_page.dart';
import 'ui/theme.dart';

/// Where the bundled livekit-server lives, or null when this build has none.
String? bundledLiveKit() {
  final exe = File(Platform.resolvedExecutable);
  final File bin;
  if (Platform.isMacOS) {
    // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Resources/livekit-server
    bin = File('${exe.parent.parent.path}/Resources/livekit-server');
  } else if (Platform.isWindows) {
    // Installed next to hubbub.exe by windows/CMakeLists.txt.
    bin = File('${exe.parent.path}\\livekit-server.exe');
  } else if (Platform.isLinux) {
    // Installed next to the executable by linux/CMakeLists.txt.
    bin = File('${exe.parent.path}/livekit-server');
  } else {
    return null;
  }
  return bin.existsSync() ? bin.path : null;
}

/// Desktops can host when a LiveKit server is bundled; everything else cannot.
/// The single-server config of the pre-hub path; the hub does not use it.
Future<AppNodeConfig> nodeConfig() async {
  final dir = await getApplicationSupportDirectory();
  final bin = bundledLiveKit();
  return AppNodeConfig(
    dataDir: dir.path,
    communityFile: '${dir.path}/community.json',
    canHost: bin != null,
    livekitBin: bin,
  );
}

/// Where the hub keeps its data: `HUBBUB_ROOT` when set (a second instance on one machine),
/// else the app support folder.
Future<String> hubRoot() async {
  final env = Platform.environment['HUBBUB_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  return (await getApplicationSupportDirectory()).path;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initCore();
  final hub = HubController(FrbHub());
  final room = LiveKitRoomAdapter();
  final root = await hubRoot();
  try {
    await hub.open(root, canHost: bundledLiveKit() != null, livekitBin: bundledLiveKit());
  } catch (e) {
    // A start at login hides the window, and there is no tray yet: show the error instead of
    // leaving an invisible process. Closing the window then ends it.
    try {
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
    runApp(StartFailed(error: '$e'));
    return;
  }
  final navigator = GlobalKey<NavigatorState>();
  final shell = PluginAppShell();
  // Self-update only exists for an installed copy; a dev run never polls a feed.
  final installedVersion = Platform.isWindows ? install.installVersion() : null;
  final installed = updaterSupported(isWindows: Platform.isWindows, installedVersion: installedVersion);
  final updates = installed ? UpdateController(service: RustUpdateService(), feed: resolveUpdateFeed()) : null;
  final lifecycle = TrayLifecycle(
    shell: shell,
    shutdown: hub.shutdown,
    beforeExit: updates?.applyBeforeExit,
    notice: HideNoticeStore.file('$root${Platform.pathSeparator}shell.json'),
    showNotice: () => showHideNotice(navigator),
  );
  _installExitHooks(lifecycle);
  await lifecycle.start();
  updates?.quit = lifecycle.quit;
  // A start at login runs with --background and the runner leaves the window hidden. Without a
  // tray there would be no way to bring it back, so show it then.
  if (args.contains('--background') && !shell.hasTray) await shell.showWindow();
  updates?.start();
  final overlay = gameOverlayFor(isWindows: Platform.isWindows, root: root);
  unawaited(overlay?.settings.start());
  runApp(HubbubApp(
      updates: updates,
      windowsSettings: installedVersion != null ? RustWindowsSettings() : null,
      hub: hub,
      room: room,
      links: WindowRevealingLinks(AppLinkSource(), shell),
      navigatorKey: navigator,
      devices: DevicePrefsStore.file('$root${Platform.pathSeparator}devices.json'),
      audio: AudioPrefsStore.file('$root${Platform.pathSeparator}audio.json'),
      overlay: overlay));
}

/// The once-only "still running" notice (the tray package has no balloon), shown just before the
/// window first hides.
Future<bool> showHideNotice(GlobalKey<NavigatorState> navigator) async {
  final context = navigator.currentContext;
  if (context == null) return false;
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Hubbub is still running'),
      content: const Text('Hubbub keeps running in the tray so your servers stay online. '
          'To quit it, right-click the Hubbub tray icon and choose Quit Hubbub.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('Got it')),
      ],
    ),
  );
  return true;
}

/// Routes every exit request through the lifecycle. The engine asks to exit when the window's X
/// is pressed: with a tray that must only hide the window (the hub keeps running), so the request is
/// cancelled; without one it shuts every server (and the livekit-server child) down first, because
/// destructors do not run on exit. Signals shut down and exit.
void _installExitHooks(TrayLifecycle lifecycle) {
  AppLifecycleListener(onExitRequested: () async =>
      await lifecycle.exitRequested() ? AppExitResponse.exit : AppExitResponse.cancel);
  for (final signal in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
    try {
      signal.watch().listen((_) => unawaited(lifecycle.quit()));
    } on SignalException {
      // Not supported on this platform.
    }
  }
}

class HubbubApp extends StatelessWidget {
  const HubbubApp(
      {super.key,
      this.updates,
      this.windowsSettings,
      required this.hub,
      required this.room,
      this.links,
      this.devices,
      this.audio,
      this.overlay,
      this.navigatorKey});

  final UpdateController? updates;
  final WindowsSettings? windowsSettings;
  final HubController hub;
  final RoomAdapter room;
  final LinkSource? links;
  final DevicePrefsStore? devices;
  final AudioPrefsStore? audio;

  /// The in-game overlay (Windows only); null elsewhere.
  final GameOverlayController? overlay;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Hubbub',
      debugShowCheckedModeBanner: false,
      theme: hubbubTheme(),
      home: HomePage(
          hub: hub,
          room: room,
          loadConfig: nodeConfig,
          linkSource: links,
          deviceStore: devices,
          audioStore: audio,
          updates: updates,
          windowsSettings: windowsSettings,
          onCallMembers: overlay?.setCall,
          overlaySettings: overlay?.settings),
    );
  }
}

/// Shown when the hub cannot open, e.g. another Hubbub already has the data folder.
class StartFailed extends StatelessWidget {
  const StartFailed({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hubbub',
        debugShowCheckedModeBanner: false,
        theme: hubbubTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Hubbub could not start.\n\n$error', textAlign: TextAlign.center),
            ),
          ),
        ),
      );
}
