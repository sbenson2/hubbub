import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'frb_hub.dart';
import 'hub_controller.dart';
import 'links.dart';
import 'node_controller.dart';
import 'room_adapter.dart';
import 'src/rust/api/hubbub.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initCore();
  final hub = HubController(FrbHub());
  final room = LiveKitRoomAdapter();
  try {
    await hub.open(await hubRoot(), canHost: bundledLiveKit() != null, livekitBin: bundledLiveKit());
  } catch (e) {
    runApp(StartFailed(error: '$e'));
    return;
  }
  _installExitHooks(hub);
  runApp(HubbubApp(hub: hub, room: room, links: AppLinkSource()));
}

/// Stops every server (and the livekit-server child) before the process ends: destructors
/// do not run on exit, so without this the media server is orphaned.
void _installExitHooks(HubController hub) {
  AppLifecycleListener(onExitRequested: () async {
    await hub.shutdown();
    return AppExitResponse.exit;
  });
  for (final signal in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
    try {
      signal.watch().listen((_) async {
        await hub.shutdown();
        exit(0);
      });
    } on SignalException {
      // Not supported on this platform.
    }
  }
}

class HubbubApp extends StatelessWidget {
  const HubbubApp({super.key, required this.hub, required this.room, this.links});

  final HubController hub;
  final RoomAdapter room;
  final LinkSource? links;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hubbub',
      debugShowCheckedModeBanner: false,
      theme: hubbubTheme(),
      home: HomePage(hub: hub, room: room, loadConfig: nodeConfig, linkSource: links),
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
