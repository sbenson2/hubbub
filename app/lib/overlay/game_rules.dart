import 'dart:math';

/// Raw facts about the foreground window, as reported by the Windows runner
/// over `dev.hubbub/overlay` (`foreground`). All rectangles are screen
/// physical pixels.
class ForegroundFacts {
  const ForegroundFacts({
    required this.hwnd,
    required this.path,
    required this.own,
    required this.windowClass,
    required this.caption,
    required this.window,
    required this.client,
    required this.monitor,
    required this.minimized,
    required this.dpi,
  });

  final int hwnd;

  /// Full exe path, or '' when the process could not be queried.
  final String path;
  final bool own;
  final String windowClass;
  final bool caption;
  final Rectangle<int> window, client, monitor;
  final bool minimized;
  final int dpi;

  /// Lower-case basename of [path]; '' when the path is empty.
  String get exeName {
    if (path.isEmpty) return '';
    final p = normalizeExePath(path);
    return p.substring(p.lastIndexOf(r'\') + 1);
  }

  /// Parses the contract map; null for null or malformed input.
  static ForegroundFacts? fromMap(Object? map) {
    if (map is! Map) return null;
    try {
      Rectangle<int> rect(Object? v) {
        if (v is! List || v.length != 4) throw const FormatException();
        final l = v[0] as int, t = v[1] as int, r = v[2] as int, b = v[3] as int;
        return Rectangle<int>(l, t, r - l, b - t);
      }

      return ForegroundFacts(
        hwnd: map['hwnd'] as int,
        path: map['path'] as String,
        own: map['own'] as bool,
        windowClass: map['cls'] as String,
        caption: map['caption'] as bool,
        window: rect(map['window']),
        client: rect(map['client']),
        monitor: rect(map['monitor']),
        minimized: map['minimized'] as bool,
        dpi: map['dpi'] as int,
      );
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ForegroundFacts &&
      other.hwnd == hwnd &&
      other.path == path &&
      other.own == own &&
      other.windowClass == windowClass &&
      other.caption == caption &&
      other.window == window &&
      other.client == client &&
      other.monitor == monitor &&
      other.minimized == minimized &&
      other.dpi == dpi;

  @override
  int get hashCode => Object.hash(hwnd, path, own, windowClass, caption,
      window, client, monitor, minimized, dpi);
}

/// Lower-case, forward slashes turned into backslashes.
String normalizeExePath(String path) =>
    path.toLowerCase().replaceAll('/', r'\');

/// Executables (lower-case basenames) that never get the overlay, even when
/// fullscreen or listed as games.
const Set<String> overlayExcludedExes = {
  // Shell
  'explorer.exe', 'shellexperiencehost.exe', 'startmenuexperiencehost.exe',
  'searchhost.exe', 'searchapp.exe', 'lockapp.exe', 'textinputhost.exe',
  'applicationframehost.exe', 'gamebar.exe',
  // Browsers
  'chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe',
  'vivaldi.exe', 'iexplore.exe', 'arc.exe', 'librewolf.exe', 'waterfox.exe',
  'zen.exe', 'floorp.exe', 'chromium.exe',
  // Video players
  'vlc.exe', 'mpc-hc.exe', 'mpc-hc64.exe', 'mpc-be.exe', 'mpc-be64.exe',
  'mpv.exe', 'potplayer.exe', 'potplayer64.exe', 'potplayermini.exe',
  'potplayermini64.exe', 'wmplayer.exe', 'video.ui.exe',
  'microsoft.media.player.exe', 'kodi.exe', 'plex.exe', 'plexhtpc.exe',
  'stremio.exe',
  // Slideshows, remote desktop and calls
  'powerpnt.exe', 'mstsc.exe', 'msrdc.exe', 'vmconnect.exe', 'teams.exe',
  'ms-teams.exe', 'zoom.exe', 'discord.exe', 'obs64.exe',
};

const Set<String> shellWindowClasses = {
  'Progman',
  'WorkerW',
  'Shell_TrayWnd',
  'Shell_SecondaryTrayWnd',
};

/// An excluded exe, any screensaver, or a shell window class.
bool isExcluded(ForegroundFacts f) {
  final exe = f.exeName;
  return overlayExcludedExes.contains(exe) ||
      exe.endsWith('.scr') ||
      shellWindowClasses.contains(f.windowClass);
}

/// Whether a game is in front. [knownGames] holds paths already passed
/// through [normalizeExePath]. Exclusions beat the game list.
bool isGameInFront(ForegroundFacts? f, Set<String> knownGames) {
  if (f == null || f.own || f.minimized) return false;
  if (isExcluded(f)) return false;
  if (f.path.isNotEmpty && knownGames.contains(normalizeExePath(f.path))) {
    return true;
  }
  return f.window.containsRectangle(f.monitor) && !f.caption;
}

/// Logical pixels from the client corner to the overlay.
const overlayMargin = 16;

/// Top-left of the overlay in screen physical px, kept on the monitor.
Point<int> overlayOrigin(ForegroundFacts f) {
  final m = (overlayMargin * f.dpi / 96).round();
  return Point<int>(
    max(f.client.left, f.monitor.left) + m,
    max(f.client.top, f.monitor.top) + m,
  );
}
