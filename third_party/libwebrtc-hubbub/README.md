# Hubbub's libwebrtc build for Windows

Hubbub's Windows app uses its own build of the webrtc-sdk/libwebrtc wrapper instead of the stock
prebuilt. This folder holds everything needed to rebuild it; the zip itself is hosted on a
GitHub prerelease (see "Publishing a build").

## Why

The stock `libwebrtc.m150.7871.03` captures Windows audio through the legacy ADM's built-in AEC
DMO, which is fixed at 16 kHz mono (muffled), and then runs AEC3 on top of it (double AEC). The
engine opens the mic before it applies the AEC options, so no setting from the app can avoid the
DMO: libwebrtc's info log shows `InitRecording` → `SetRecordingSampleRate(16000)` before the
voice channel options arrive. Two patches fix it, both in `wrapper.patch`:

- **A** (`patches/disable_win_builtin_aec_dmo.patch`, applied to the WebRTC sources by the wrapper's
  build script): the DMO is never created, so `BuiltInAECIsAvailable()` is false and capture always
  takes the shared WASAPI path at the device rate.
- **B** (`src/rtc_audio_processing_impl.cc`): the audio processing module runs at 48 kHz, so the
  capture hook gets `Initialize(48000, 1)` and `Process(bands=3, frames=480)`.

Verified: 48 kHz capture, AEC3 only. Linux and macOS are unaffected (they keep upstream's prebuilt).

## Pins

| What | Value |
|---|---|
| Wrapper | `webrtc-sdk/libwebrtc` tag `libwebrtc.m150.7871.03` = commit `070aa6d` |
| Our change | `wrapper.patch` (3 files, 43 lines), applied by `sync.cmd` |
| WebRTC sources | `webrtc-sdk/webrtc` commit `ba469aa2093ba950066258ca0a59a6fbd1295582` (`R_COMMIT` in `sync.cmd`) |
| gn args | the same as stock (`build.cmd` is the wrapper's own line, with `rtc_include_tests=true`) |

Nothing else differs from stock: same source commit, same arguments, same output layout.

## Prerequisites

- Windows 10/11 x64, Git, and `tar.exe` (ships with Windows).
- Visual Studio 2022 BuildTools (C++ workload) with the Windows SDK 10.0.26100 including *Debugging
  Tools for Windows* (`build.cmd` stops with `NEED_DEBUGGING_TOOLS` without `dbghelp.dll`).
- About 30 GB free for the first sync. On the maintainer's desktop the sync took about 20 min and
  the build about 18 min.

## Rebuilding

From `cmd.exe` (from WSL, start in `/mnt/c` first so cmd has a drive cwd, not a UNC path):

    set WORK=C:\wrtc\work        (optional, this is the default)
    third_party\libwebrtc-hubbub\sync.cmd     (clones, syncs, applies patches; prints SYNC_OK)
    third_party\libwebrtc-hubbub\build.cmd    (gn, ninja, zip; prints the zip's sha256, then BUILD_OK)

Output in `%WORK%`:

- `libwebrtc-x64-release\` (`LICENSE`, `include\`, `lib\libwebrtc.dll`, `lib\libwebrtc.dll.lib`)
- `libwebrtc-win-x64-release.zip` of that folder, written with `tar.exe -a -c -f` so the entry
  names use forward slashes (PowerShell 5.1 `Compress-Archive` writes backslashes, which
  non-Windows extractors mishandle).

`sync.cmd` re-checks out the wrapper at `070aa6d` and re-applies `wrapper.patch` each run. Both
scripts are CRLF (`.gitattributes`). `sync.cmd` has two traps already handled: every `git` is
`call git` (depot_tools' shim ends the script otherwise), and `echo.` precedes the `target_os`
line (`.gclient` may lack a trailing newline).

## Publishing a build

1. Pick the tag: `libwebrtc.m150.7871.03-hubbub1`; for a rebuilt zip bump the suffix (`-hubbub2`).
   Never reuse a tag, because the CMake cache is keyed by it.
2. Create a zip-only prerelease on this repo. It must never become "latest": the app's update feed
   reads `releases/latest/download/releases.win.json`.

       gh release create libwebrtc.m150.7871.03-hubbub1 --prerelease --latest=false ^
         --title "libwebrtc m150.7871.03 (Hubbub, Windows)" --notes "..." ^
         %WORK%\libwebrtc-win-x64-release.zip

3. In `third_party/flutter_webrtc/third_party/libwebrtc_version.ini` set `win_binary_version` to
   the tag and `win_x64_sha256` to the zip's sha256. CMake verifies the hash on every configure
   and re-extracts when the version or hash changes.
4. Run the fullband audio suite at 48000 and the echo matrix before an app release ships the new DLL.

## Licensing

- The wrapper is MIT, WebRTC is BSD-3 plus the `PATENTS` grant; patches A and B add no dependency.
- The gn args pull in more: OpenH264 (BSD-2, `rtc_use_h264`), FFmpeg's H.264 decoder
  (`ffmpeg_branding="Chrome"`, LGPL-2.1+, probably linked statically), libvpx, libaom, dav1d,
  Opus, BoringSSL and abseil. H.265 uses the Windows Media Foundation codec (nothing bundled).
- Distributing the zip makes us the distributor of those binaries. H.264/H.265 are patent-pooled;
  Cisco's OpenH264 cover applies only to Cisco-built binaries. The exposure equals using the stock
  prebuilt, but we now ship it. The LGPL part needs source and relink availability; this folder
  plus the public sources and the pinned commits is probably enough. Both are owner calls.
- The zip contains only the wrapper's MIT `LICENSE`. A full notice file
  (`src\tools_webrtc\libs\generate_licenses.py`) and R's `LICENSE` and `PATENTS` are not shipped yet.
