import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'src/rust/api/install.dart' as rust;

/// Where installed copies look for a newer release: a folder of static files (the installer
/// feed `releases.win.json` and the packages), e.g. a GitHub release's `latest/download`.
/// Replace `<OWNER>` once the public releases repo exists, or build with
/// `--dart-define=HUBBUB_UPDATE_FEED=<url or folder>`. A feed still holding the placeholder is
/// never contacted.
const kUpdateFeed = String.fromEnvironment('HUBBUB_UPDATE_FEED',
    defaultValue: 'https://github.com/<OWNER>/hubbub-releases/releases/latest/download');

/// The feed to use: the `HUBBUB_UPDATE_FEED` environment variable (a local folder to try an
/// update without a server) over the built-in one. Null when it is still the placeholder.
String? resolveUpdateFeed({String compiled = kUpdateFeed, Map<String, String>? env}) {
  final fromEnv = (env ?? Platform.environment)['HUBBUB_UPDATE_FEED'];
  final feed = fromEnv != null && fromEnv.isNotEmpty ? fromEnv : compiled;
  return feed.isEmpty || feed.contains('<OWNER>') ? null : feed;
}

/// Whether this run polls for updates. Only an installed Windows copy does. Linux ships the
/// AppImage as a manual download for now: an unproven updater that can exit the process at
/// startup is a worse risk than updating by hand.
bool updaterSupported({required bool isWindows, required String? installedVersion}) =>
    isWindows && installedVersion != null;

/// Downloading and installing a newer Hubbub. The real one is [RustUpdateService]; tests fake it.
abstract class UpdateService {
  /// The newer version in [feed], or null when this is the latest. Throws when it cannot tell
  /// (offline, no feed yet, a copy that was not installed).
  Future<String?> check(String feed);

  /// Downloads what [check] found. Returns its version.
  Future<String> download(String feed);

  /// The version downloaded earlier and waiting for a restart, if any.
  String? pending();

  /// Arranges for the update to be installed once this process has exited, relaunching the app
  /// when [restart]. The caller shuts the hub down and exits right after.
  void applyOnExit({required bool restart});
}

class RustUpdateService implements UpdateService {
  @override
  Future<String?> check(String feed) => rust.updateCheck(feed: feed);

  @override
  Future<String> download(String feed) => rust.updateDownload(feed: feed);

  @override
  String? pending() => rust.updatePending();

  @override
  void applyOnExit({required bool restart}) => rust.updateApplyOnExit(restart: restart);
}

enum UpdatePhase { idle, checking, downloading, ready }

/// The update state machine behind the "Update ready - Restart" banner. It checks on [start] and
/// every [interval], downloads in the background, and only ever restarts when the user presses
/// Restart and no call is up. An update that is ready is applied on the next quit either way.
/// Every failure is silent: a missing or unreachable feed just means no update.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.service,
    required this.feed,
    this.interval = const Duration(hours: 6),
  }) {
    final waiting = service.pending();
    if (waiting != null) {
      _phase = UpdatePhase.ready;
      _version = waiting;
    }
  }

  final UpdateService service;

  /// Null disables checking (the feed is not configured yet).
  final String? feed;
  final Duration interval;

  /// Set by the home page while a call is up; a restart is refused then.
  final callActive = ValueNotifier<bool>(false);

  /// Shuts the hub down and exits (the tray's Quit). Set once the lifecycle exists.
  Future<void> Function()? quit;

  UpdatePhase _phase = UpdatePhase.idle;
  String? _version;
  bool _restartRequested = false;
  Timer? _timer;

  UpdatePhase get phase => _phase;

  /// The version that is downloading or ready.
  String? get version => _version;

  bool get ready => _phase == UpdatePhase.ready;

  /// Restart now is offered only when an update is ready and no call is up.
  bool get canRestartNow => ready && !callActive.value;

  void start() {
    _timer?.cancel();
    unawaited(check());
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  /// One check-and-download pass; does nothing while one is running or an update is ready.
  Future<void> check() async {
    final url = feed;
    if (url == null || _phase != UpdatePhase.idle) return;
    _set(UpdatePhase.checking);
    try {
      final found = await service.check(url);
      if (found == null) return _set(UpdatePhase.idle);
      _version = found;
      _set(UpdatePhase.downloading);
      _version = await service.download(url);
      _set(UpdatePhase.ready);
    } catch (e) {
      debugPrint('update check: $e'); // silent: offline and no-feed-yet are normal
      _version = null;
      _set(UpdatePhase.idle);
    }
  }

  /// The banner's Restart button. Returns false (and does nothing) when it is not allowed.
  Future<bool> restart() async {
    if (!canRestartNow || quit == null) return false;
    _restartRequested = true;
    await quit!();
    return true;
  }

  /// Runs in the quit path after the hub has shut down: hands a ready update to the updater,
  /// which installs it once this process is gone (and relaunches if Restart was pressed).
  void applyBeforeExit() {
    if (!ready) return;
    try {
      service.applyOnExit(restart: _restartRequested);
    } catch (e) {
      debugPrint('could not hand the update to the updater: $e');
    }
  }

  void _set(UpdatePhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    callActive.dispose();
    super.dispose();
  }
}

/// The Windows-only switches in User Settings, behind a seam so the toggle is tested without
/// the registry. The real one is [RustWindowsSettings].
abstract class WindowsSettings {
  bool get startAtLogin;
  void setStartAtLogin(bool on);

  /// The installed version, or null for a copy that is not installed (a dev run).
  String? get version;
}

class RustWindowsSettings implements WindowsSettings {
  @override
  bool get startAtLogin => rust.startAtLogin();

  @override
  void setStartAtLogin(bool on) => rust.setStartAtLogin(on_: on);

  @override
  String? get version => rust.installVersion();
}
