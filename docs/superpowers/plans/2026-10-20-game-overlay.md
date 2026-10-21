# Game Overlay (Windows) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While you are in a Hubbub voice call and a game is in front, show Discord-style avatar bubbles in the game's top-left corner, with the green ring lighting up when someone speaks.

**Architecture:**
- The Windows runner owns a thin native layer: a click-through layered popup (pixels, position, topmost, excluded from capture) and a `SetWinEventHook` watcher that reports raw foreground-window facts.
- Dart makes every decision as pure, testable code: is a game in front, which rows show, the layout and the settings. Flutter's own widgets (`Avatar`, `CrossedIcon`) are rendered offscreen into premultiplied RGBA, which goes to the popup over the `dev.hubbub/overlay` channel.
- Task 1 proves that offscreen rendering works while the main window is hidden in the tray. If it doesn't, the native fallback at the end of this plan replaces only the rasterizing step.

**Tech Stack:**
- Flutter 3.47.7 and Dart 3.13.5 (`C:\src\flutter`).
- Win32 C++ in `app/windows/runner`: user32, gdi32, dwmapi and advapi32, all already linked.
- `MethodChannel` with `StandardMethodCodec`, and `flutter_test` goldens.

**Spec:** `docs/superpowers/specs/2026-10-20-game-overlay-design.md`, approved by the owner. Executors read it first.

## Global Constraints

**Platform**
- Windows only. macOS and Linux must build and run unchanged.
  - There, the overlay is a no-op: `gameOverlayFor` returns null, and no `dev.hubbub/overlay` call is ever made.
  - No runner outside `app/windows` changes.

**Anti-cheat safety**
- Never inject into, hook or read a game process.
- The only process access allowed is `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` plus `QueryFullProcessImageNameW`. Never ask for `PROCESS_VM_READ`, debug rights or module enumeration.
- Every `SetWinEventHook` uses `WINEVENT_OUTOFCONTEXT`.

**The overlay window**
- It is never activated, is click-through, has no taskbar or Alt+Tab entry, and is only as big as the bubbles.
- It is topmost and is re-asserted with `SWP_NOACTIVATE` and `SW_SHOWNOACTIVATE`.
- It is hidden from capture with `WDA_EXCLUDEFROMCAPTURE`.
  - The developer switch `HUBBUB_OVERLAY_CAPTURABLE=1` (environment variable) skips this, so screenshots can verify the overlay.
  - On Windows older than 10 2004, the affinity call fails; ignore the failure and show the window anyway.
- Redraw only when something visible changes: speaking, mute, deafen, join or leave, settings, DPI. A move only moves.

**Dependencies and engine**
- No new pub dependencies.
- No second Flutter engine or window.

**Settings**
- Defaults: overlay on, Large avatars, names Always, users Always.
- Stored in `<data root>\overlay.json` through `writeFileAtomic`, following the `AudioPrefs` / `AudioPrefsStore` pattern.

**Copy and branding**
- Use exactly: "Game Overlay", "Enable in-game overlay", "Avatar size" (Large / Small), "Display names" (Always / Only while speaking / Never), "Display users" (Always / Only while speaking).
- Help line: "The overlay shows in windowed and borderless games. Some games in exclusive fullscreen need their display mode set to borderless."
- No Discord name, logo or artwork anywhere in the app.

**Git**
- Use Windows git from a Windows cwd. Write the message to `/mnt/c/wrtc/overlay-msg.txt`, then run `cd /mnt/c/wrtc && cmd.exe /c "cd /d C:\dev\hubbub && git add <explicit paths> && git commit -F C:\wrtc\overlay-msg.txt"`.
- Commit one task at a time, on `main`. Each message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never stage these always-modified noise files:
  - both `generated_plugin_registrant.h`
  - `app/test/dialogs_test.dart`
  - `app/test/links_test.dart`
  - `core/src/proto.rs`
- Nothing is pushed before Task 9's owner-confirmed step.

**Tests and analysis**
- One test file: `cd /mnt/c/wrtc && cmd.exe /c "cd /d C:\dev\hubbub\app && C:\src\flutter\bin\flutter.bat test test\<file>"`.
- The full suite uses the same command with no file, under `timeout 230`. The baseline is 339 pass and 9 skipped; new tests add to it.
- `flutter.bat analyze` has 3 existing issues, all in `test\screenshots`. Add none.

**Native builds**
- Runner C++ compiles only through a Flutter build.
- Implementers compile-check with `cd /mnt/c/wrtc && timeout 230 cmd.exe /c "cd /d C:\dev\hubbub\app && C:\src\flutter\bin\flutter.bat build windows --debug"`. The Debug build doesn't touch the running Release tray app.
- If the build times out (the first Debug build may be cold), stop and hand back to the main session, which runs it in the background.

**Running the Release app (main session only)**
- The tray app runs from `app\build\windows\x64\runner\Release`. Quit it with `hubbub.exe --quit` from that folder before a Release build; the owner may be in a call, so ask first.
- Launching, screenshots and anything that takes longer than 4 minutes belong to the main session.

## Review Focus

These five inputs aren't exercised by the spec's own tests but are likely to bite a user. Each has a pinning test in the task named.

1. **An excluded app that Windows also lists as a game**, such as `chrome.exe` in GameConfigStore after a stray Win+G. The overlay must not show over a browser, so exclusions beat the game list (Task 2: `an_excluded_app_in_the_game_list_still_hides`).
2. **A foreground process whose path can't be read** (an elevated or protected game, `QueryFullProcessImageNameW` fails). The fullscreen rule still applies, and shell window classes still hide. Never retry with stronger access rights (Task 2: `an_unreadable_path_still_uses_the_fullscreen_rule`, `an_unreadable_path_with_a_shell_class_hides`).
3. **A maximized ordinary window that covers the whole monitor**, which happens with an auto-hide taskbar (Notepad, an IDE). It isn't fullscreen or borderless, so no overlay: a captioned window never qualifies through the fullscreen rule (Task 2: `a_captioned_window_covering_the_monitor_is_not_fullscreen`).
4. **Speaking flips faster than a draw completes.** Draws never queue up; they collapse to the latest state, and the final image matches the final state (Task 6: `changes_during_a_draw_collapse_to_the_latest`).
5. **Nothing to show, or a failed native call.** "Display users: Only while speaking" with everyone quiet must hide the window, never send an empty image. A failed `setImage` must not wedge the controller (Task 6: `nobody_to_show_hides_instead_of_drawing`, `a_failed_draw_is_retried_on_the_next_change`).

## Channel contract: `dev.hubbub/overlay`

| Direction | Method | Arguments | Result |
|---|---|---|---|
| Dart → native | `setImage` | `{rgba: Uint8List, width: int, height: int}`: premultiplied RGBA, top-down, physical px | `null`; error `bad_image` if `rgba.length != width*height*4` or a side is 0 |
| Dart → native | `place` | `{x: int, y: int}`: screen physical px of the top-left | `null`; moves, re-asserts topmost, shows without activating |
| Dart → native | `hide` | none | `null` |
| Dart → native | `start` | none | `null`; installs hooks, and current facts follow at once |
| Dart → native | `stop` | none | `null`; unhooks and hides |
| Dart → native | `knownGames` | none | `List<String>`: every `MatchedExeFullPath` under `HKCU\System\GameConfigStore\Children\*` |
| native → Dart | `foreground` | facts map, or `null` when there's no foreground window | ignored |

The facts map is `{hwnd: int, path: String ('' if unreadable), own: bool, cls: String, caption: bool, window: [l,t,r,b], client: [l,t,r,b], monitor: [l,t,r,b], minimized: bool, dpi: int}`.
- All rectangles are screen physical px (the runner is PerMonitorV2).
- `window` is `DWMWA_EXTENDED_FRAME_BOUNDS`, falling back to `GetWindowRect`.
- `client` is the client area in screen coordinates.
- `caption` is `(GWL_STYLE & WS_CAPTION) == WS_CAPTION`.
- `dpi` is the window's monitor's DPI.

## File map

New files in `app/lib/overlay/`:

| File | Task | Contents |
|---|---|---|
| `overlay_renderer.dart` | 1 | offscreen widget → `OverlayBitmap` |
| `overlay_spike.dart` | 1 | temporary; deleted in Task 7 |
| `game_rules.dart` | 2 | `ForegroundFacts`, exclusions, `isGameInFront`, `overlayOrigin` |
| `overlay_prefs.dart` | 3 | prefs, store, `OverlaySettings` |
| `overlay_scene.dart` | 4 | `OverlayRow`, `OverlayScene`, `overlayRows` |
| `overlay_view.dart` | 4 | `OverlayLook`, `GameOverlayView`, `rasterizeScene` |
| `overlay_host.dart` | 5 | `OverlayHost`, `ChannelOverlayHost` |
| `game_overlay.dart` | 6–7 | `GameOverlayController`, `gameOverlayFor` |

New native files in `app/windows/runner/`:
- `overlay_window.{h,cpp}` (Task 1)
- `foreground_watcher.{h,cpp}` (Task 5)

New tool: `tools/overlay-test-window.ps1` (Task 5).

---

### Task 1: Spike: layered window and offscreen image while the main window is hidden

**Files:**
- Create: `app/windows/runner/overlay_window.h`, `app/windows/runner/overlay_window.cpp`
- Modify: `app/windows/runner/flutter_window.h`, `app/windows/runner/flutter_window.cpp` (new channel beside `session_channel_`), `app/windows/runner/CMakeLists.txt` (add `"overlay_window.cpp"`)
- Create: `app/lib/overlay/overlay_renderer.dart`, `app/lib/overlay/overlay_spike.dart`
- Modify: `app/lib/main.dart` (spike hook)
- Test: `app/test/overlay_renderer_test.dart`

**Interfaces:**
- Produces (Dart):
  - `class OverlayBitmap { const OverlayBitmap({required this.rgba, required this.width, required this.height}); final Uint8List rgba; final int width, height; }`. The pixels are premultiplied RGBA, top-down, in physical px.
  - `Future<OverlayBitmap> renderOverlayImage(Widget child, {required double pixelRatio})`.
- Produces (native, `overlay_window.h`):
  ```cpp
  class OverlayWindow {
   public:
    OverlayWindow();   // creates the hidden popup, class L"HubbubGameOverlay"
    ~OverlayWindow();
    bool SetImage(const std::vector<uint8_t>& rgba, int width, int height);  // false: empty/mismatched
    void Place(int x, int y);  // HWND_TOPMOST, no activate, shows if hidden
    void Hide();
    HWND hwnd() const;
  };
  ```
- Produces the channel methods `setImage`, `place` and `hide`, as in the contract table.

- [ ] **Step 1: Write the failing tests** in `app/test/overlay_renderer_test.dart`. Each runs its render inside `tester.runAsync`.
  ```dart
  testWidgets('renders_at_physical_size_with_premultiplied_rgba', (tester) async {
    final bmp = (await tester.runAsync(() => renderOverlayImage(
        const SizedBox(width: 40, height: 20, child: ColoredBox(color: Color(0x80FF0000))),
        pixelRatio: 1.5)))!;
    expect((bmp.width, bmp.height), (60, 30));
    expect(bmp.rgba.length, 60 * 30 * 4);
    expect(bmp.rgba.sublist(0, 4), [closeTo(128, 1), 0, 0, closeTo(128, 1)]); // premultiplied
  });
  // uncovered_pixels_are_fully_transparent: a 20×20 SizedBox holding Align(topLeft) with a
  //   10×10 opaque box at ratio 1 → the alpha byte of pixel (15,15) == 0.
  // the_size_follows_the_content: Row(mainAxisSize: min) of two 30×10 boxes at ratio 1 → 60×10.
  ```
- [ ] **Step 2: Run them and check that they fail.** Run the `overlay_renderer_test.dart` command; it fails because `overlay_renderer.dart` doesn't exist yet.
- [ ] **Step 3: Implement `renderOverlayImage`.** Build a detached tree that never schedules a frame. While the window is hidden, `SchedulerBinding` turns frames off for `AppLifecycleState.hidden`, so nothing may depend on frames.
  1. Create a `RenderRepaintBoundary`.
  2. Wrap it in `RenderPositionedBox(alignment: Alignment.topLeft)`.
  3. Put that under a `RenderView` with `view: WidgetsBinding.instance.platformDispatcher.implicitView!` and `ViewConfiguration(logicalConstraints: const BoxConstraints(maxWidth: 1000, maxHeight: 2000), devicePixelRatio: pixelRatio)`.
  4. Use your own `PipelineOwner` and `BuildOwner(focusManager: FocusManager())`.
  5. Attach the widget with `RenderObjectToWidgetAdapter` (exported from `widgets.dart` in this SDK), wrapping it in `Directionality(textDirection: TextDirection.ltr)`.
  6. Run `buildScope` and `finalizeTree`, then `flushLayout`, `flushCompositingBits` and `flushPaint`.
  7. Capture with `boundary.toImage(pixelRatio:)` and `toByteData(format: ImageByteFormat.rawRgba)`. That format is premultiplied (see `sky_engine/lib/ui/painting.dart`).
  8. Dispose the image. Keep nothing between calls.
- [ ] **Step 4: Run the tests and check that they pass.** Expected: 3 pass.
- [ ] **Step 5: Implement `OverlayWindow`.** Pinned values:
  - **Styles:** ex-style `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, style `WS_POPUP`, no owner.
  - **Window procedure:** `WM_NCHITTEST` → `HTTRANSPARENT`; `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`; `WM_DPICHANGED` → `0` (`SetImage` alone sets the size).
  - **Capture:** unless `GetEnvironmentVariableW(L"HUBBUB_OVERLAY_CAPTURABLE")` starts with `1`, call `SetWindowDisplayAffinity(hwnd, 0x00000011 /*WDA_EXCLUDEFROMCAPTURE*/)` and ignore a failure.
  - **`SetImage`:**
    1. Make a 32-bpp top-down DIB section (`biHeight = -height`).
    2. Copy the pixels with R and B swapped. The data is already premultiplied, so only the channel order changes.
    3. Call `UpdateLayeredWindow(hwnd, nullptr, nullptr, &size, memdc, &zero, 0, &blend, ULW_ALPHA)` with `BLENDFUNCTION{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA}`. A null `pptDst` keeps the position.
  - **`Place`:** `SetWindowPos(hwnd, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER)`, then `ShowWindow(hwnd, SW_SHOWNOACTIVATE)` if `!IsWindowVisible`.
  - **`Hide`:** `ShowWindow(hwnd, SW_HIDE)`.
- [ ] **Step 6: Wire the channel in `FlutterWindow`.**
  - Add `overlay_channel_` (`dev.hubbub/overlay`, `StandardMethodCodec`) next to `session_channel_`. Set its method-call handler in `OnCreate`, and reset it in `OnDestroy` before the controller.
  - Create the `std::unique_ptr<OverlayWindow> overlay_` lazily on the first call.
  - Read ints with a helper that accepts both `int32_t` and `int64_t`.
  - Bad arguments → `result->Error("bad_args")`. `SetImage` returning false → `result->Error("bad_image")`.
- [ ] **Step 7: Add the temporary spike driver**, `Future<void> runOverlaySpike({MethodChannel channel = const MethodChannel('dev.hubbub/overlay')})`. Task 7 deletes it.
  - **Loop:** once a second for 120 ticks, render
    `Row(mainAxisSize: min, [Avatar(id: 'ad27', name: 'Spike', size: 32, speaking: n.isOdd, background: Color(0x00000000)), SizedBox(width: 6), <tag "spike $n · ${lastMs} ms">])`
    at the implicit view's `devicePixelRatio`. Then call `setImage`, and on the first tick also `place(100, 100)`.
  - **Tag:** `Color(0xB31E1F22)` with radius 4. Text is `hubFont` 14, w600, white.
  - **`lastMs`:** the previous tick's render-plus-send time, from a `Stopwatch`.
  - **Hook:** in `main()`, after `runApp`, add `if (Platform.isWindows && Platform.environment['HUBBUB_OVERLAY_SPIKE'] == '1') unawaited(runOverlaySpike());`.
- [ ] **Step 8: Compile-check.** Run the Debug build command. Expected: it ends with `Built build\windows\x64\runner\Debug\hubbub.exe`. If it times out, hand back to the main session.
- [ ] **Step 9: Analyze.** Expected: 3 issues, the existing ones only.
- [ ] **Step 10: Commit** the 9 files listed under **Files** with the message "Overlay spike: layered window and offscreen image".
- [ ] **Step 11: Manual check (main session; needs a Release build and the real desktop).**
  1. Quit the tray app and build Release in the background.
  2. Launch with `cmd.exe /c "set HUBBUB_OVERLAY_SPIKE=1&& set HUBBUB_OVERLAY_CAPTURABLE=1&& start "" C:\dev\hubbub\app\build\windows\x64\runner\Release\hubbub.exe"`. Then check:
     - a. The bubble appears at physical (100,100) within 2 s.
     - b. Close the main window with X; it goes to the tray. Two screenshots taken 3 s apart show the counter advancing and the ring alternating. **This is the gate.**
     - c. Run `hubbub.exe --quit`, then relaunch the same way with `--background` added, so the window is never shown. Check b again.
     - d. In a crop of the avatar at 4×, the circle's edge blends into the desktop with no dark or light fringe.
     - e. With Notepad under the bubble, a click on the bubble's pixels lands in Notepad, and Notepad keeps focus. The taskbar and Alt+Tab show no extra window.
     - f. Relaunch without `HUBBUB_OVERLAY_CAPTURABLE`. A PowerShell P/Invoke check finds `FindWindow("HubbubGameOverlay")` visible at its rectangle, yet a screenshot of that rectangle doesn't contain the bubble.
     - g. Record the `ms` figure.
  3. Relaunch the tray app normally afterwards.
  - **Outcome:** if b and c pass, take the Flutter route and continue to Task 2. If either fails, tell the owner and switch to the **Fallback** section before Task 4.

### Task 2: Game rules (pure Dart)

**Files:**
- Create: `app/lib/overlay/game_rules.dart`
- Test: `app/test/overlay_rules_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class ForegroundFacts {            // == and hashCode over every field
    const ForegroundFacts({required this.hwnd, required this.path, required this.own,
        required this.windowClass, required this.caption, required this.window,
        required this.client, required this.monitor, required this.minimized, required this.dpi});
    final int hwnd; final String path; final bool own; final String windowClass; final bool caption;
    final Rectangle<int> window, client, monitor;   // dart:math, screen physical px
    final bool minimized; final int dpi;
    String get exeName;                             // lower-case basename of path; '' if path is ''
    static ForegroundFacts? fromMap(Object? map);   // contract map → facts; null for null/malformed
  }
  String normalizeExePath(String path);             // lower-case, '/' → '\'
  const Set<String> overlayExcludedExes;            // lower-case basenames, below
  const Set<String> shellWindowClasses = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};
  bool isExcluded(ForegroundFacts f);               // excluded exe, any '*.scr', or a shell class
  bool isGameInFront(ForegroundFacts? f, Set<String> knownGames);   // knownGames already normalized
  const overlayMargin = 16;                         // logical px from the client corner
  Point<int> overlayOrigin(ForegroundFacts f);
  ```
- The members of `overlayExcludedExes`:
  - **Shell:** `explorer.exe shellexperiencehost.exe startmenuexperiencehost.exe searchhost.exe searchapp.exe lockapp.exe textinputhost.exe applicationframehost.exe gamebar.exe`
  - **Browsers:** `chrome.exe msedge.exe firefox.exe brave.exe opera.exe vivaldi.exe iexplore.exe arc.exe librewolf.exe waterfox.exe zen.exe floorp.exe chromium.exe`
  - **Video players:** `vlc.exe mpc-hc.exe mpc-hc64.exe mpc-be.exe mpc-be64.exe mpv.exe potplayer.exe potplayer64.exe potplayermini.exe potplayermini64.exe wmplayer.exe video.ui.exe microsoft.media.player.exe kodi.exe plex.exe plexhtpc.exe stremio.exe`
  - **Slideshows, remote desktop and calls:** `powerpnt.exe mstsc.exe msrdc.exe vmconnect.exe teams.exe ms-teams.exe zoom.exe discord.exe obs64.exe`

- [ ] **Step 1: Write the failing tests.**
  - **Fixtures:** `mon = Rectangle(0, 0, 1920, 1080)`. The helper `f({path = r'C:\Games\Foo\Foo.exe', cls = 'UnityWndClass', caption = false, window = mon, client = mon, own = false, minimized = false, dpi = 96, hwnd = 1})` builds facts.
  - **Tests:**
    - `no_foreground_is_not_a_game`: `isGameInFront(null, {})` is false.
    - `hubbub_itself_never_counts`: `f(own: true)` is false.
    - `a_minimized_window_never_counts`: `f(minimized: true)` is false.
    - `a_fullscreen_unknown_exe_counts`: `f()` with `{}` is true.
    - `a_borderless_window_overhanging_the_monitor_counts`: `window: Rectangle(-1, -1, 1922, 1082)` is true.
    - `a_known_game_in_a_window_counts_case_insensitively`: `window` and `client` set to `Rectangle(100, 100, 1280, 720)`, `caption: true`, known `{r'c:\games\foo\foo.exe'}` → true. With `{}` → false.
    - `a_maximized_window_short_of_the_taskbar_is_not_fullscreen`: `window: Rectangle(0, 0, 1920, 1032)`, `caption: true` → false.
    - `a_captioned_window_covering_the_monitor_is_not_fullscreen` (Review Focus 3): `caption: true`, `window: mon` → false.
    - `browsers_players_slideshows_remote_and_calls_hide`: for each of `chrome.exe`, `vlc.exe`, `POWERPNT.EXE`, `mstsc.exe` and `Zoom.exe` as a fullscreen path, the result is false.
    - `an_excluded_app_in_the_game_list_still_hides` (Review Focus 1): path `C:\Program Files\Google\Chrome\Application\chrome.exe`, also in known games → false.
    - `the_desktop_hides`: path `C:\Windows\explorer.exe`, cls `WorkerW` → false.
    - `a_screensaver_hides`: `C:\Windows\System32\Mystify.scr` → false.
    - `an_unreadable_path_still_uses_the_fullscreen_rule` (Review Focus 2): `path: ''`, fullscreen → true.
    - `an_unreadable_path_with_a_shell_class_hides` (Review Focus 2): `path: ''`, cls `Progman` → false.
    - `the_origin_is_the_client_corner_plus_the_scaled_margin`: `client: Rectangle(100, 200, 800, 600)`, `dpi: 144` → `Point(124, 224)`.
    - `the_origin_stays_on_the_monitor`: `client: Rectangle(-50, -30, 800, 600)` → `Point(16, 16)`.
    - `facts_parse_from_the_native_map`: the contract map with `path: r'C:\Games\Foo\Foo.exe'`, `window: [0, 0, 1920, 1080]` and `dpi: 144` gives `window == mon`, `exeName == 'foo.exe'` and `dpi == 144`. `fromMap(null)` is null. A map missing `dpi`, or with a 3-element rectangle, is null.
- [ ] **Step 2: Run the tests and check that they fail.** Expected: compile errors, because the library doesn't exist yet.
- [ ] **Step 3: Implement.**
  - `isGameInFront` checks in this order:
    1. null, `own` or `minimized` → false.
    2. `isExcluded` → false. Exclusions beat the game list (from the spec's anti-goals).
    3. A non-empty path in `knownGames` (normalized) → true.
    4. `window.containsRectangle(monitor) && !caption` → true.
    5. Otherwise false.
  - `overlayOrigin`: `m = (overlayMargin * dpi / 96).round()`; `x = max(client.left, monitor.left) + m`, and the same for y.
  - Rectangles arrive as `[l, t, r, b]` and become `Rectangle(l, t, r - l, b - t)`.
- [ ] **Step 4: Run the tests and check that they pass.**
- [ ] **Step 5: Commit** `game_rules.dart` and its test with the message "Overlay: game-in-front rules".

### Task 3: Overlay settings and the "Game Overlay" section

**Files:**
- Create: `app/lib/overlay/overlay_prefs.dart`
- Modify: `app/lib/ui/settings_dialog.dart` (new `_Section.overlay`, nav item, section widget, `showSettingsDialog` parameter)
- Test: `app/test/overlay_prefs_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum OverlayAvatarSize { large, small }
  enum OverlayNames { always, whileSpeaking, never }
  enum OverlayUsers { always, whileSpeaking }
  class OverlayPrefs {              // == and hashCode; copyWith for every field
    const OverlayPrefs({this.enabled = true, this.avatarSize = OverlayAvatarSize.large,
        this.names = OverlayNames.always, this.users = OverlayUsers.always});
    Map<String, Object?> toJson();  // {"enabled":true,"avatarSize":"large","names":"always","users":"always"}
    static OverlayPrefs fromJson(Object? j);   // a missing or unknown value → its default
  }
  class OverlayPrefsStore {         // same shape as AudioPrefsStore
    OverlayPrefsStore.file(String path); OverlayPrefsStore.memory([OverlayPrefs? initial]);
    Future<OverlayPrefs> load(); Future<void> save(OverlayPrefs p);
  }
  class OverlaySettings extends ChangeNotifier {
    OverlaySettings(OverlayPrefsStore store);
    OverlayPrefs get prefs;
    Future<void> start();                  // loads, notifies
    Future<void> update(OverlayPrefs p);   // sets, notifies, saves
  }
  ```
- `showSettingsDialog` gains `OverlaySettings? overlay`. The section shows only when it's non-null.

- [ ] **Step 1: Write the failing tests.**
  - **Prefs and store:**
    - `defaults_are_on_large_always_always`.
    - `json_round_trips_and_bad_values_fall_back`:
      - `fromJson(p.toJson()) == p` for a non-default `p`.
      - `fromJson({'avatarSize': 'huge', 'enabled': 'yes'}) == const OverlayPrefs()`.
      - `fromJson(42) == const OverlayPrefs()`.
    - `the_file_store_saves_and_loads` (temp dir):
      - A missing file loads the defaults.
      - After `save(p)`, `load() == p`.
      - A file of garbage text loads the defaults.
    - `update_notifies_and_saves`: one listener call, and `store.load()` returns the new prefs.
  - **Dialog** (pump like `install_test.dart`'s Windows Settings group, at 1400×900, DPR 1):
    - `the_section_shows_only_with_overlay_settings`: "Game Overlay" is found once with `overlay:` and not at all without it.
    - `each_control_updates_the_settings_live`: after tapping "Game Overlay":
      - `Key('overlay-enabled')` is a `SwitchListTile` with value true. Tapping it → `prefs.enabled` is false.
      - Tapping `Key('overlay-size-small')` → `avatarSize == small`.
      - Tapping `Key('overlay-names-whileSpeaking')`, then `Key('overlay-names-never')` → `names == never`.
      - Tapping `Key('overlay-users-whileSpeaking')` → `users == whileSpeaking`.
      - The help line is found by its exact text.
- [ ] **Step 2: Run the tests and check that they fail.**
- [ ] **Step 3: Implement.**
  - `OverlayPrefsStore` mirrors `AudioPrefsStore`: `writeFileAtomic`, and errors go to `debugPrint`.
  - **Dialog layout:**
    - Nav order: My Account, Voice & Video, Game Overlay, then Windows Settings.
    - Section content, top to bottom:
      1. `SwitchListTile` titled "Enable in-game overlay".
      2. The `HubText.category` headings "AVATAR SIZE", "DISPLAY NAMES" and "DISPLAY USERS", each with radio rows.
      3. The help line, in the muted 14 px style that `low-light-full-frame-rate` uses.
  - **Radio rows:** a small private `_ChoiceRow(label, selected, onTap, key)`, styled like `_NoiseChoice` without its description line. Keys follow `overlay-<group>-<enum.name>`.
  - **Labels:** Large, Small; Always, Only while speaking, Never.
- [ ] **Step 4: Run the tests and check that they pass.** Run `overlay_prefs_test.dart`, then `install_test.dart`, which must stay green.
- [ ] **Step 5: Commit** the 3 files with the message "Overlay: settings and Game Overlay section".

### Task 4: Rows, the overlay widget, and goldens

**Files:**
- Create: `app/lib/overlay/overlay_scene.dart`, `app/lib/overlay/overlay_view.dart`
- Test: `app/test/overlay_view_test.dart`, goldens `app/test/goldens/overlay_large.png` and `app/test/goldens/overlay_small.png`

**Interfaces:**
- Consumes:
  - `VoiceMember` (`ui/channel_sidebar.dart`)
  - `Avatar`, `CrossedIcon` (`ui/avatar.dart`)
  - `OverlayPrefs` and the enums (Task 3)
  - `renderOverlayImage`, `OverlayBitmap` (Task 1)
- Produces:
  ```dart
  class OverlayRow {     // == and hashCode
    const OverlayRow({required this.id, required this.name, required this.speaking,
        required this.muted, required this.deafened, required this.showName});
  }
  class OverlayScene {   // == and hashCode (listEquals on rows)
    const OverlayScene({required this.rows, required this.avatarSize, required this.pixelRatio});
    final List<OverlayRow> rows; final OverlayAvatarSize avatarSize; final double pixelRatio;
  }
  List<OverlayRow> overlayRows(List<VoiceMember> members, OverlayPrefs prefs);
  abstract final class OverlayLook { ... }   // every size and colour below; nothing hard-coded elsewhere
  class GameOverlayView extends StatelessWidget { const GameOverlayView({super.key, required this.scene}); }
  Future<OverlayBitmap> rasterizeScene(OverlayScene scene);   // renderOverlayImage(GameOverlayView(scene), pixelRatio: scene.pixelRatio)
  ```

**`OverlayLook` starting values** (Step 5 checks them against Discord). Logical px; Large / Small where two values are given.

| Value | Large | Small |
|---|---|---|
| Avatar | 32 | 24 |
| Name text: `hubFont`, w600, `HubColors.white`, height 1.2 | 14 | 12 |
| Tag height | 24 | 20 |
| Tag horizontal padding | 8 | 6 |
| Gap from avatar to tag | 6 | 4 |
| Mute and deafen icons | 16 | 14 |

| Value | Both sizes |
|---|---|
| Tag colour | `Color(0xB31E1F22)` |
| Tag radius | 4 |
| Tag maximum width (name ellipsizes) | 200 |
| Gap between rows | 4 |
| Opacity of a quiet row | 0.6 |
| Opacity of a speaking row | 1 |
| Icon colour | `HubColors.interactive` |
| Icon strike | `HubColors.red` |
| Strike background | `HubColors.rail` |

- **Row:** `Avatar(size, speaking, background: Color(0x00000000))`, then the tag, which holds the name if `showName`, then the mic and headphone `CrossedIcon`s as the sidebar shows them.
  - With no name and no icon, there's no tag. With no name but an icon, the tag holds only the icons.
  - Use no `Tooltip`, `HostCrown`, `Material` or anything that needs an `Overlay` or `Navigator` above it: the view renders offscreen with only `Directionality`.
  - The layout is a `Column(mainAxisSize: min, crossAxisAlignment: start)`, with each row keyed `Key('overlay-row:<id>')`.

- [ ] **Step 1: Write the failing tests.**
  - **Fixtures:** `me`, `maya`, `theo` and `priya` are `VoiceMember`s with ids `memberIdFor('ad27')` and so on, in that order.
  - **Row selection:**
    - `rows_follow_the_member_order_and_include_me`: ids in order, `me` included.
    - `users_while_speaking_lists_only_speakers`: only speaking members, still in order.
    - `names_while_speaking_shows_only_speaking_names`: `showName == speaking`.
    - `names_never_hides_every_name`.
    - `mute_and_deafen_carry_over`: a deafened member gives `muted: true, deafened: true`, as the sidebar shows both.
  - **Widget:**
    - `a_quiet_row_is_dimmed_and_a_speaking_row_is_not`: the row's `Opacity` is 0.6 when quiet and 1.0 when speaking; `Avatar.speaking` matches.
    - `muted_shows_a_crossed_mic_and_deafened_adds_headphones`: 1 `CrossedIcon` (`Icons.mic_rounded`) for muted; 2 for deafened, adding `Icons.headphones_rounded`.
    - `a_hidden_name_leaves_only_the_avatar_unless_muted`.
    - `a_long_name_ellipsizes_at_the_tag_limit`: with a 60-character name, the tag width is at most `OverlayLook.maxTagWidth`.
    - `sizes_follow_the_avatar_setting`: `Avatar.size` is 32 for large and 24 for small.
    - `rasterize_scene_is_the_view_at_the_scene_ratio` (inside `runAsync`): 2 large rows at 1.5 give `height == ((2 * 32 + 4) * 1.5).ceil()`.
  - **Goldens:** `golden_overlay_large` and `golden_overlay_small`, with `skip: kIsWeb` and `loadAppFonts()` in `setUpAll`, as in `goldens_test.dart`.
    - Rows: me speaking; maya quiet and muted; theo quiet and deafened; priya speaking.
    - The view is padded by 16 over a `LinearGradient` from `Color(0xFFBFD4E6)` to `Color(0xFF3D5A3D)` (top to bottom), so legibility on light and dark backgrounds both show.
    - The view is 320×180 at DPR 1. Golden files: `goldens/overlay_large.png` and `goldens/overlay_small.png`.
- [ ] **Step 2: Run the tests and check that they fail.**
- [ ] **Step 3: Implement** `overlay_scene.dart` and `overlay_view.dart` as specified above.
- [ ] **Step 4: Create the goldens.** Run `flutter.bat test --update-goldens test\overlay_view_test.dart`, then the plain run. Expected: everything passes.
- [ ] **Step 5: Check against Discord.**
  - Compare the goldens with reference screenshots of Discord's current (2025+) in-game voice widget. Search for "Discord overlay voice widget", and see Discord's "Game Overlay 101" help article.
  - Where they differ (sizes, quiet opacity, tag colour or padding, icon position), change only the `OverlayLook` values or the row structure. Regenerate the goldens.
  - List the reference URLs in the commit body.
- [ ] **Step 6: Commit** the 3 source and test files and the 2 PNGs with the message "Overlay: rows, widget and goldens".
- [ ] **Step 7: Show the goldens (main session).** Show the owner both goldens beside the reference. This is informational, not a gate.

### Task 5: Native foreground watcher, Windows' game list, and the Dart host

**Files:**
- Create: `app/windows/runner/foreground_watcher.h`, `app/windows/runner/foreground_watcher.cpp`
- Modify: `app/windows/runner/flutter_window.h`, `app/windows/runner/flutter_window.cpp`, `app/windows/runner/CMakeLists.txt`
- Create: `app/lib/overlay/overlay_host.dart`, `tools/overlay-test-window.ps1`
- Modify: `app/lib/overlay/overlay_spike.dart` (facts readout)
- Test: `app/test/overlay_host_test.dart`

**Interfaces:**
- Consumes:
  - `ForegroundFacts`, `normalizeExePath`, `isGameInFront` (Task 2)
  - `OverlayScene` (Task 4)
  - `OverlayBitmap` (Task 1)
  - the `OverlayWindow` channel methods (Task 1)
- Produces (Dart):
  ```dart
  typedef OverlayRasterizer = Future<OverlayBitmap> Function(OverlayScene scene);
  abstract class OverlayHost {
    Stream<ForegroundFacts?> get foreground;   // broadcast; one event per native 'foreground' call
    Future<void> start();
    Future<void> stop();
    Future<Set<String>> knownGames();          // normalized with normalizeExePath
    Future<void> show(OverlayScene scene, Point<int> origin);   // rasterize, setImage, then place
    Future<void> move(Point<int> origin);      // place only (also re-asserts topmost)
    Future<void> hide();
  }
  class ChannelOverlayHost implements OverlayHost {
    ChannelOverlayHost({required OverlayRasterizer rasterize,
        MethodChannel channel = const MethodChannel('dev.hubbub/overlay')});
  }
  ```
- Produces (native):
  ```cpp
  constexpr UINT kOverlayFactsMessage = WM_APP + 0x52;   // flutter_window.h, beside kQuitMessage
  class ForegroundWatcher {
   public:
    ForegroundWatcher(HWND post_to, std::function<void(flutter::EncodableValue)> on_facts);
    ~ForegroundWatcher();   // Stop()
    void Start();           // foreground + minimize hooks, then Schedule()
    void Stop();            // unhook everything
    void Schedule();        // post one kOverlayFactsMessage unless one is pending
    void Flush();           // on kOverlayFactsMessage: re-hook location if the pid changed, send facts
  };
  flutter::EncodableValue FactsFor(HWND foreground);   // contract map, or EncodableValue() for null
  std::vector<std::string> KnownGamePaths();           // UTF-8, via Utf8FromUtf16
  ```

- [ ] **Step 1: Write the failing tests** in `overlay_host_test.dart`. They use `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`, and a fake rasterizer that returns `OverlayBitmap(rgba: Uint8List(8), width: 2, height: 1)`.
  - `show_sends_the_image_then_the_place`: the method names are `['setImage', 'place']`, with arguments `{'rgba': Uint8List(8), 'width': 2, 'height': 1}`, then `{'x': 24, 'y': 40}`.
  - `move_and_hide_send_place_and_hide`.
  - `start_stop_and_known_games`: the native side returns `[r'C:\Games\Foo.EXE']`, which becomes `{r'c:\games\foo.exe'}`.
  - `native_foreground_calls_become_facts`: deliver `MethodCall('foreground', <contract map>)` through `handlePlatformMessage`; the stream emits equal `ForegroundFacts`. `null` → `null`. A malformed map → `null`.
- [ ] **Step 2: Run the tests and check that they fail.**
- [ ] **Step 3: Implement `overlay_host.dart`.** The constructor installs the channel's method-call handler for `foreground`.
- [ ] **Step 4: Run the tests and check that they pass.**
- [ ] **Step 5: Implement `foreground_watcher.cpp`.**
  - **Hooks** (all `WINEVENT_OUTOFCONTEXT`):
    - `EVENT_SYSTEM_FOREGROUND`, process 0.
    - `EVENT_SYSTEM_MINIMIZESTART..EVENT_SYSTEM_MINIMIZEEND`, process 0.
    - `EVENT_OBJECT_LOCATIONCHANGE`, scoped to the foreground window's pid, with `| WINEVENT_SKIPOWNPROCESS`. It's re-registered in `Flush` when that pid changes.
  - **Callback:** the static `WINEVENTPROC` uses one static instance pointer. For a location change, it ignores everything except `hwnd == tracked_ && idObject == OBJID_WINDOW && idChild == CHILDID_SELF`. Every accepted event calls `Schedule()`.
  - **Coalescing:** `Schedule` posts at most one message at a time (`pending_` flag), so a window drag collapses to the message-loop rate.
  - **`FactsFor`:** builds each contract field.
    - `path`: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `QueryFullProcessImageNameW`, or `''` on failure. Always close the handle.
    - `own`: the window's pid equals `GetCurrentProcessId()`.
    - `cls`: `GetClassNameW`.
    - `caption`: from `GetWindowLongW(GWL_STYLE)`.
    - `window`: `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, falling back to `GetWindowRect`.
    - `client`: `GetClientRect` + `ClientToScreen`.
    - `monitor`: `MonitorFromWindow(MONITOR_DEFAULTTONEAREST)` + `GetMonitorInfoW`, `rcMonitor`.
    - `dpi`: `FlutterDesktopGetDpiForMonitor`.
    - `minimized`: `IsIconic`.
  - **`KnownGamePaths`:** `RegOpenKeyExW(HKEY_CURRENT_USER, L"System\\GameConfigStore\\Children", 0, KEY_READ)`, `RegEnumKeyExW`, then `RegGetValueW(sub, L"MatchedExeFullPath", RRF_RT_REG_SZ)`. Skip empty values. A missing key gives an empty list.
- [ ] **Step 6: Extend `FlutterWindow`.**
  - Create `watcher_` in `OnCreate`, with `GetHandle()` as the window to post to and a callback that does `overlay_channel_->InvokeMethod("foreground", …)`.
  - Handle the new methods: `start` → `watcher_->Start()`; `stop` → `watcher_->Stop()` and hide the overlay; `knownGames` → an `EncodableList` of strings.
  - In `MessageHandler`, before Flutter's handler: `kOverlayFactsMessage` → `Flush()` and return 0. `WM_DISPLAYCHANGE` → `Schedule()` and fall through.
  - Destroy `watcher_` in `OnDestroy` before the channel.
- [ ] **Step 7: Write `tools/overlay-test-window.ps1`.**
  - Usage: `param([ValidateSet('borderless','windowed')][string]$Mode = 'borderless', [int]$Seconds = 120)`.
  - It shows a WinForms form with background `#2B3A55` and a centered label "Hubbub overlay test window (Esc closes)".
  - **Borderless:** `FormBorderStyle = None`, with `Bounds` set to the primary screen's full bounds, covering the taskbar.
  - **Windowed:** a sizable window, 1280×720.
  - Esc closes it (`KeyPreview`), and so does a timer after `$Seconds`.
  - Run it with `powershell -NoProfile -ExecutionPolicy Bypass -File tools\overlay-test-window.ps1 -Mode borderless`.
- [ ] **Step 8: Extend the spike readout.**
  - The spike calls `start` and `knownGames` once, and handles `foreground` with `ForegroundFacts.fromMap`.
  - The tag gets a second line: `'${f?.exeName ?? 'none'} ${f?.dpi ?? 0}dpi${f?.minimized == true ? ' min' : ''} game:${isGameInFront(f, games)}'`.
- [ ] **Step 9: Check the game list.** Run `cmd.exe /c "reg query HKCU\System\GameConfigStore\Children /s /v MatchedExeFullPath"`.
  - Record the number of `MatchedExeFullPath` lines and two sample paths in the commit body.
  - If the key is missing or empty, rule 3a is inert on this machine and no code changes; say so in the commit body.
- [ ] **Step 10: Compile-check and analyze.** Expected: Debug build `Built …`; analyze shows 3 issues.
- [ ] **Step 11: Commit** the native files, `CMakeLists.txt`, `overlay_host.dart`, `overlay_spike.dart`, the test and the script, with the message "Overlay: foreground watcher, game list, channel host".
- [ ] **Step 12: Readout check (main session; Release build).**
  1. Launch with `HUBBUB_OVERLAY_SPIKE=1` and `HUBBUB_OVERLAY_CAPTURABLE=1`, and hide the main window to the tray.
  2. Screenshot each of the following and check the expected readout:

  | In front | Expected readout |
  |---|---|
  | The borderless test window | `powershell.exe … game:true` |
  | The `windowed` test window | `game:false` |
  | Maximized Edge | `msedge.exe game:false` |
  | The desktop (Win+D) | `explorer.exe game:false` |
  | Hubbub's own window | `hubbub.exe game:false` |
  | Minimized | `min` |

  3. Dragging the windowed test window makes no extra `game:true`.
  4. If a second monitor has a different scale, the DPI shown changes when the window moves across.

### Task 6: GameOverlayController

**Files:**
- Create: `app/lib/overlay/game_overlay.dart`, `app/test/support/fake_overlay.dart`
- Test: `app/test/game_overlay_test.dart`

**Interfaces:**
- Consumes:
  - `OverlayHost` (Task 5)
  - `OverlaySettings` and `OverlayPrefs` (Task 3)
  - `overlayRows`, `OverlayScene` (Task 4)
  - `isGameInFront`, `isExcluded`, `overlayOrigin`, `normalizeExePath` (Task 2)
- Produces:
  ```dart
  const gameListRefresh = Duration(seconds: 30);
  class GameOverlayController {
    GameOverlayController({required OverlayHost host, required this.settings,
        DateTime Function() clock = DateTime.now});
    final OverlaySettings settings;
    void setCall(List<VoiceMember>? members);   // sidebar order; null = not in a call
    Future<void> dispose();
  }
  ```
- `FakeOverlayHost implements OverlayHost` lives in `test/support/fake_overlay.dart`:
  - `calls` (`List<String>`) records `'start'`, `'stop'`, `'knownGames'`, `'show x,y'`, `'move x,y'` and `'hide'`.
  - `scenes` (`List<OverlayScene>`) records each scene shown.
  - `Set<String> games` is what `knownGames` returns.
  - `void emit(ForegroundFacts? f)` sends facts.
  - `Completer<void>? showGate` makes `show` wait.
  - `bool failNextShow` makes the next `show` throw a `PlatformException`.

**Algorithm**, the part the tests don't fully determine:
- **One apply loop at a time.** Each input (`setCall`, a settings notification, facts) sets `_dirty` and kicks the loop. While a host call is in flight, more kicks only set `_dirty`, so the next pass sees only the latest state.
- **Each pass:**
  1. `active = members != null && prefs.enabled`.
  2. If it changed:
     - Became active: `start()`, then `knownGames()`.
     - Became inactive: `stop()`, and forget the facts and the shown scene.
  3. If active, the facts are present, `!own`, the path is non-empty, `!isExcluded`, the path isn't in the game list, and the list was read at least `gameListRefresh` ago: refetch `knownGames()`.
  4. Compute `rows = overlayRows(members, prefs)`.
  5. Not (`isGameInFront && rows.isNotEmpty`) → `hide()` if the overlay is visible.
  6. Otherwise `scene = OverlayScene(rows: rows, avatarSize: prefs.avatarSize, pixelRatio: facts.dpi / 96)` and `origin = overlayOrigin(facts)`:
     - The scene changed → `show(scene, origin)`.
     - Otherwise, if the overlay is hidden, the origin changed or `hwnd` changed → `move(origin)`. This is the topmost re-assert.
- **Errors:** catch every host error and `debugPrint` it. A failed `show` clears the remembered scene, so the next pass redraws.

- [ ] **Step 1: Write the failing tests.**
  - **Setup:** plain `test()`s, each followed by `await pumpEventQueue()`, with `OverlaySettings(OverlayPrefsStore.memory())` and a mutable fake clock.
  - **Fixtures:**
    - `game({hwnd = 1, dpi = 96, client})`: fullscreen `C:\Games\Foo\Foo.exe` on a 1920×1080 monitor.
    - `windowed(path, client)`: `caption: true`.
    - `desktop()`: `explorer.exe`, `WorkerW`.
  - **Tests:**
    - `nothing_starts_outside_a_call`: `calls` is empty after `setCall(null)` and `emit(game())`.
    - `a_call_starts_the_watcher_and_reads_the_game_list`: `['start', 'knownGames']`.
    - `a_fullscreen_game_shows_the_rows_at_its_corner`:
      - `calls.last == 'show 16,16'`.
      - `scenes.last == OverlayScene(rows: [OverlayRow(id: me.id, name: 'Shawn', speaking: false, muted: false, deafened: false, showName: true)], avatarSize: OverlayAvatarSize.large, pixelRatio: 1.0)`.
    - `leaving_the_game_hides_and_returning_moves_without_redrawing`: desktop → `'hide'`; game → `'move 16,16'`; `scenes.length` doesn't change.
    - `only_a_visible_change_redraws`: an equal member list in a new instance → no call. Speaking → exactly one more `show`.
    - `a_window_move_only_moves`: a known windowed game whose client moves from (100,100) to (300,200) → `'move 316,216'`; no new scene.
    - `a_dpi_change_redraws_at_the_new_ratio`: dpi 96 → 144 → `'show 24,24'` and `pixelRatio == 1.5`.
    - `switching_between_two_games_reasserts_the_window`: `game(hwnd: 1)` then `game(hwnd: 2)` → `'move 16,16'`.
    - `leaving_the_call_stops_the_watcher`: `calls.last == 'stop'`.
    - `the_setting_applies_live`: enabled false → `'stop'`. Enabled true → `'start', 'knownGames'`; after `emit(game())` → `show`.
    - `a_settings_change_redraws`: `avatarSize: small` → `scenes.last.avatarSize == small`.
    - `nobody_to_show_hides_instead_of_drawing` (Review Focus 5): with `users: whileSpeaking` and all quiet, a visible overlay → `'hide'`, and no `show` happens with empty rows.
    - `changes_during_a_draw_collapse_to_the_latest` (Review Focus 4):
      - Set `showGate`, then make me speak, which starts a `show`.
      - Then: quiet, speaking, muted.
      - Release the gate. There are exactly 2 shows in total, and `scenes.last.rows.single` has `speaking: true, muted: true`.
    - `a_failed_draw_is_retried_on_the_next_change` (Review Focus 5): `failNextShow` → the first show throws. The next speaking change → a second `show` that succeeds.
    - `an_unknown_windowed_exe_is_rechecked_after_30_s`:
      - `windowed(r'C:\New\Game.exe')` → no show. Then `games = {r'c:\new\game.exe'}`.
      - +10 s, emit a move → no `'knownGames'`.
      - +21 s, emit again → `'knownGames'`, then a show.
    - `dispose_stops_a_started_watcher`.
- [ ] **Step 2: Run the tests and check that they fail.**
- [ ] **Step 3: Implement** `GameOverlayController` as specified above.
- [ ] **Step 4: Run the tests and check that they pass.**
- [ ] **Step 5: Commit** the 3 files with the message "Overlay: controller".

### Task 7: Wire it into the app and remove the spike

**Files:**
- Modify: `app/lib/overlay/game_overlay.dart` (`gameOverlayFor`), `app/lib/ui/home_page.dart`, `app/lib/main.dart`
- Delete: `app/lib/overlay/overlay_spike.dart`
- Test: `app/test/home_page_test.dart`, `app/test/game_overlay_test.dart`

**Interfaces:**
- Produces:
  - `GameOverlayController? gameOverlayFor({required bool isWindows, required String root})`. It returns null unless `isWindows`. Otherwise it returns a controller built from `ChannelOverlayHost(rasterize: rasterizeScene)` and `OverlaySettings(OverlayPrefsStore.file('$root${Platform.pathSeparator}overlay.json'))`.
  - New `HomePage` parameters:
    - `final void Function(List<VoiceMember>? members)? onCallMembers;`
    - `final OverlaySettings? overlaySettings;`
  - `HubbubApp` gains `final GameOverlayController? overlay;`.

- [ ] **Step 1: Write the failing tests.**
  - `no_overlay_off_windows` in `game_overlay_test.dart`: `gameOverlayFor(isWindows: false, root: tmp)` is null; with `isWindows: true` it's non-null.
  - `the_overlay_hears_the_call_speaking_mute_and_leave` in `home_page_test.dart`. Give `pumpShell` an optional `onCallMembers` and record into `seen`.
    1. Before the join: `seen.isEmpty || seen.last == null`.
    2. After `joinLobby`: `seen.last!.single` is `isMe` and named `'Shawn'`.
    3. `room.emitParticipants([me speaking, Bob quiet])` + pump → `[('Shawn', true), ('Bob', false)]` as `(name, speaking)`.
    4. Tap Mute → `seen.last!.first.muted` is true.
    5. Disconnect → `seen.last` is null.
- [ ] **Step 2: Run the tests and check that they fail.**
- [ ] **Step 3: Implement the wiring.**
  - **`_HomePageState`:**
    - Override `setState` to call `super.setState(fn)`, then `_syncOverlay()`.
    - `_syncOverlay()` calls `widget.onCallMembers?.call(_call == null ? null : _voiceMembers)`.
    - `dispose()` first calls `widget.onCallMembers?.call(null)`.
    - `_openSettings` passes `overlay: widget.overlaySettings`.
    - Why `setState` and not `build()`: frames are off while the window is hidden, so `build` doesn't run. Every member, speaking, mute and call change already goes through `setState`.
  - **`main.dart`:**
    - Remove the spike hook.
    - Add `final overlay = gameOverlayFor(isWindows: Platform.isWindows, root: root); unawaited(overlay?.settings.start());`.
    - Pass `overlay` to `HubbubApp`, which hands `onCallMembers: overlay?.setCall` and `overlaySettings: overlay?.settings` to `HomePage`.
  - Delete `overlay_spike.dart`.
- [ ] **Step 4: Run the tests.** Run the two test files, then the full suite under `timeout 230`. Expected: 339 + new tests pass, 9 skipped.
- [ ] **Step 5: Analyze and compile-check.** Expected: 3 issues; the Debug build succeeds.
- [ ] **Step 6: Commit** `game_overlay.dart`, `home_page.dart`, `main.dart`, the deletion of `overlay_spike.dart`, and the 2 tests, with the message "Overlay: wire into the app".

### Task 8: Real-app verification (main session)

There are no code changes unless a check fails. A failure goes back to a fix task with its own test.

- [ ] **Step 1: Build and launch.** With the owner's OK, quit the tray app and build Release in the background. Launch with `HUBBUB_OVERLAY_CAPTURABLE=1`, join a voice channel, and hide the main window to the tray.
- [ ] **Step 2: It shows over games.**
  - **Borderless:** with `overlay-test-window.ps1 -Mode borderless` in front, a screenshot shows the bubbles at the monitor's top-left plus 16×scale. Keyboard input still reaches the test window; Esc closes it.
  - **Fullscreen:** an installed game in its fullscreen mode, or Godot 4 run with `--fullscreen` on any project if no game is installed. The overlay shows; the game keeps focus and isn't minimized. Note any exclusive-fullscreen game where it doesn't show; that's a non-goal.
  - **Windowed:** a windowed game that Windows lists, if one is installed. The bubbles follow a drag of its window.
- [ ] **Step 3: It hides elsewhere.** Screenshots show no overlay over:
  - the desktop (Win+D);
  - Edge, maximized and in F11 fullscreen;
  - Hubbub's own window;
  - the `windowed` test window.
- [ ] **Step 4: The ring follows speech.** The owner speaks, or plays audio near the mic, for 5 s while screenshots are taken. The local row lights green within about 100 ms of speech, at full opacity, then dims afterwards. With a second participant (a second instance with `HUBBUB_ROOT`, or a friend), their row lights too.
- [ ] **Step 5: The window's size and styles.** A PowerShell P/Invoke check of `FindWindow("HubbubGameOverlay")` finds:
  - a `GetWindowRect` size equal to the bubble stack, not the monitor;
  - `GWL_EXSTYLE` containing `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST`.
- [ ] **Step 6: It's hidden from capture.** Relaunch without the switch. The window is visible (`IsWindowVisible`), but a screenshot of its rectangle doesn't contain it.
- [ ] **Step 7: CPU cost.** Over the borderless test window, with nobody speaking, measure `(Get-Process hubbub).CPU` over 60 s with the overlay on, then again with it off. The difference is under 0.5 s. Record the figure for continuous speech as well.
- [ ] **Step 8: Settings apply live.** Screenshot the Game Overlay settings section for the owner. Switching "Display users" to "Only while speaking" makes quiet rows disappear at once; "Small" shrinks the bubbles.
- [ ] **Step 9: Report.** Give the owner the screenshots and figures.

### Task 9: Release 0.1.2 (the owner confirms before anything is published)

**Files:**
- Modify: `app/pubspec.yaml` (`version: 0.1.2-beta.1+3` → `version: 0.1.2+4`)

- [ ] **Step 1: Bump the version.** Change the version line and commit `app/pubspec.yaml` with the message "Release: 0.1.2".
- [ ] **Step 2: Build Release (main session).** Quit the tray app with the owner's OK, then run `flutter.bat build windows --release` in the background. Expected: `Built build\windows\x64\runner\Release\hubbub.exe`.
- [ ] **Step 3: Package.** Run `cmd.exe /c "cd /d C:\dev\hubbub && powershell -File tools\package-windows.ps1"`. `dist\windows` then contains:
  - `Hubbub-0.1.2-full.nupkg`
  - `Hubbub-0.1.2-delta.nupkg`
  - `releases.win.json`, listing 0.1.2
  - `HubbubSetup.exe`
- [ ] **Step 4: Scan for secrets.** Run `cd /mnt/c/dev/hubbub && gitleaks git .`. Expected: "no leaks found". Fix any real hit before going on.
- [ ] **Step 5: Owner confirms first, then publish.**
  1. Push with `cmd.exe /c "cd /d C:\dev\hubbub && git push origin main"`.
  2. Follow `docs/RELEASING.md` steps 4–5. Create release `v0.1.2` with `gh release create v0.1.2 --latest`, uploading:
     - `HubbubSetup.exe`
     - `releases.win.json`
     - the 0.1.2 full and delta packages
     - every earlier `*-full.nupkg` and `*-delta.nupkg` that `releases.win.json` still lists, from `dist\windows`
  3. It must be the latest release, not a pre-release, so every install updates to it, including the 0.1.2-beta.1 testers.
- [ ] **Step 6: Verify the feed.** `curl -sL https://github.com/sbenson2/hubbub/releases/latest/download/releases.win.json` contains `0.1.2`.
- [ ] **Step 7: Relaunch.** Relaunch the tray app and tell the owner the release is out. Frame rate and G-Sync feedback from the owner and friend is feedback on 0.1.2, not a gate.

## Fallback: native drawing, only if Task 1's gate fails

- **What stays:** `overlay_scene.dart` (rows and scene), `GameOverlayView` and its goldens (now the reference look), `OverlayHost`, the controller, every test except `rasterize_scene_*`, and the channel name.
- **What replaces Task 4's `rasterizeScene` route:** a native task that adds `app/windows/runner/overlay_draw.{h,cpp}`.
  - It draws an `OverlayScene` into the same DIB with Direct2D (`ID2D1DCRenderTarget` bound to the memory DC, premultiplied BGRA) and DirectWrite.
  - It loads `data\flutter_assets\assets\fonts\NotoSans-*.ttf` through a custom font set (`IDWriteFactory5`), matching every `OverlayLook` value and `avatarColor`.
- **Channel change:** `setImage` becomes `drawScene` with arguments `{rows: [{id, name, color: int ARGB, speaking, muted, deafened, showName}], large: bool, pixelRatio: double}`. `ChannelOverlayHost.show` sends `drawScene` and then `place`; nothing else changes.
- **Removed:** `renderOverlayImage` and its tests.
- **Verification:** compare the native output with the goldens by screenshot in Task 8.
