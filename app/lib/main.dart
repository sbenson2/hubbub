import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initCore();
  final controller = NodeController();
  final room = LiveKitRoomAdapter();
  _installExitHooks(controller);
  runApp(HubbubApp(controller: controller, room: room));
}

/// Stops the node (and its livekit-server child) before the process ends: destructors
/// do not run on exit, so without this the media server is orphaned.
void _installExitHooks(NodeController controller) {
  AppLifecycleListener(onExitRequested: () async {
    await controller.shutdown();
    return AppExitResponse.exit;
  });
  for (final signal in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
    try {
      signal.watch().listen((_) async {
        await controller.shutdown();
        exit(0);
      });
    } on SignalException {
      // Not supported on this platform.
    }
  }
}

class HubbubApp extends StatelessWidget {
  const HubbubApp({super.key, required this.controller, required this.room});

  final NodeController controller;
  final RoomAdapter room;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hubbub',
      debugShowCheckedModeBanner: false,
      theme: hubbubTheme(),
      home: HomePage(controller: controller, room: room, loadConfig: nodeConfig),
    );
  }
}
