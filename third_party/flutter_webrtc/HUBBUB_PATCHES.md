# Hubbub patches to flutter_webrtc 1.6.2+hotfix.4

Upstream: https://github.com/flutter-webrtc/flutter-webrtc (MIT, `LICENSE` kept). This is the
version livekit_client 2.13.1 pins. The app uses it through `dependency_overrides` in
`app/pubspec.yaml`.

Git history is the diff: commit `24913d5` is the pristine pub.dev package (minus `example/` and the
downloaded libwebrtc prebuilt); every later commit touching `third_party/flutter_webrtc` is a patch.
`git diff 24913d5 -- third_party/flutter_webrtc` shows all of them (the pristine commit is the stable
reference; do not use `HEAD~1`). Line endings are as upstream (`third_party/.gitattributes` is `* -text`):
`windows/CMakeLists.txt` is CRLF, the rest of the files touched are LF.

Not vendored (downloaded at CMake configure time by upstream's `third_party/CMakeLists.txt` from
`third_party/libwebrtc_version.ini`, libwebrtc.m150.7871.03): `third_party/downloads/`,
`third_party/libwebrtc/` (headers, `libwebrtc.dll`, `.lib`, `.so`). They are git-ignored by
`third_party/.gitignore` (repository level). A fresh checkout needs network
access on its first Windows or Linux build.

## What the patches add

A capture post-processor for Windows and Linux. libwebrtc m150's
`RTCAudioProcessing::SetCapturePostProcessing` is honoured (proved by `hubbub_test/apm_probe.cc`
against the prebuilt DLL: `Initialize`, then `Process` about 100 times a second with real microphone
samples). The processor runs after echo cancellation, noise suppression and AGC and does, in order:

1. RNNoise (optional), at 48 kHz in 480 sample frames. The APM hands the processor floats in the
   16-bit range at its internal rate (16 kHz mono on Windows, 48 kHz mono on Linux; see "Buffer
   layout"), so a windowed-sinc rational resampler brings other rates to 48 kHz and back. Switching
   it on or off cross-fades over one block (and stays dry until RNNoise has real output), so it does
   not click.
   **Latency added while RNNoise is on** (measured by cross-correlation, `TestLatency` in
   `hubbub_audio_test`): about 20 ms at 48 kHz and about 30 ms at 16 and 32 kHz. The 20 ms is
   RNNoise's own (the 10 ms frame it works on plus its overlap-add window); at other rates a further
   10 ms comes from waiting for a whole 48 kHz frame (the up-resampler's group delay pushes the end of
   each frame into the next block; the output is zero filled for the first block, then 9 samples at
   16 kHz). With RNNoise off the processor adds no delay.
2. Input gain 0 to 2 (ramped across each block), then a soft limiter (tanh above 85 percent of full
   scale) so 200 percent cannot clip. The limiter is always in the path, also at gain 1.0 (it is the
   identity below 85 percent of full scale, so ordinary speech is bit-transparent at gain 1.0 with
   RNNoise off; only peaks above the knee are rounded).
3. Peak meter: pre-gain and post-gain peaks, RNNoise speech probability, and the share of 10 ms blocks
   whose pre-gain peak was at least 0.98, every 50 ms. "Pre" is measured where this hook runs, that is
   after the APM's echo cancellation, noise suppression and (on Windows, where it stays on) AGC, so
   it is the level that would have been sent without Hubbub's gain, not the raw device level.

Quieter libwebrtc logs: `EnsureWebRTCInitialized` (`common/cpp/src/flutter_webrtc_base.cc`) sets
`LibWebRTCLogging::setMinDebugLogLevel(Warning)`. The prebuilt library logs to stderr at Info, and
there the frame cryptor prints the raw end-to-end key, which journald keeps on Linux.

## Buffer layout (measured, `hubbub_test/apm_probe`, prebuilt libwebrtc m150)

| Where | `Initialize` | `Process(num_bands, num_frames, buffer_size)` | Notes |
|---|---|---|---|
| Windows (WASAPI mic, Opus negotiated) | 16000 Hz, 1 channel | 1, 160, 160 | stays 16 kHz mono with stereo Opus requested, with AEC/NS/AGC on or off, on both microphones |
| Linux (PulseAudio, WSLg) | 48000 Hz, 1 channel | 3, 480, 480 | `num_frames` is the full-band count; a 1 kHz plus 10 kHz test tone arrives in those 480 samples with its 10 kHz part intact (5998 of 6000), also with AEC/NS/AGC on |

So the buffer is merged full-band audio even when `num_bands` is 3: the processor treats any block
whose `num_frames` equals `rate / 100` as full band. Channels come from `Initialize` and are assumed
planar, `num_frames` apart (stereo was not reachable: libwebrtc kept the APM at one channel here;
the adapter test covers the layout with a synthetic buffer). A block that does not fit (frame
count not `rate / 100`, in particular `num_frames * num_bands == rate / 100`, which would mean
the bands are stored apart) is passed through untouched, counted (`skipped` in `hubbubGetStatus`
and in the `hubbubLayout` event, logged by the app as `hubbub: apm ...`) and logged once per
`Initialize` on stderr. `Initialize` is logged as `hubbub: apm init rate=... ch=...`.

## libwebrtc quirk: never unregister

`SetCapturePostProcessing(nullptr)` crashes in the prebuilt m150 wrapper (access violation on
Windows, SIGSEGV on Linux; `apm_probe unregister-null`). The plugin therefore never unregisters.
At teardown it calls `CaptureProcessor::Shutdown()` (the processor turns inert and waits for a
`Process` call in flight) and leaves the object alive until the process exits. Replacing the
registered processor with another non-null one while capture runs is fine (`apm_probe teardown`).

## Threads

libwebrtc calls `Initialize/Process/Reset/Release` on its capture thread. Setters and getters run on
the platform thread and only touch atomics (`CaptureSettings`: gain, RNNoise on/off; counters). The
levels go through a lock-free slot (`LevelsSlot`, a seqlock); a publisher thread in
`flutter_webrtc_base.cc` polls it every 50 ms and queues the `hubbubLevels` event on the plugin's
task runner, so the audio thread builds no maps, calls no channel and allocates nothing in steady state.
`onDeviceChange` (called from a device thread) is routed through the same task runner.

### Task runners run tasks without their mutex

Upstream `TaskRunnerWindows::ProcessTasks` and the `TaskRunnerLinux` invoke callback ran every task while
holding the non-recursive `tasks_mutex_`. `EventChannelProxyImpl::Success` -> `PostEvent` enqueues a task, so a
task that called `Success` (the levels and layout publish tasks) re-locked the mutex on the platform thread and
deadlocked it. Both runners now swap the queue into a local under the lock and run it unlocked (FIFO kept; tasks
enqueued meanwhile run in the next round). On Linux `g_main_context_invoke` runs the callback inline when the
caller owns the context, so the callback also returns at once if it is already draining (`draining_`), which keeps
strict FIFO; a small RAII guard clears `draining_` even if a task throws, so one bad task cannot strand the queue
(test: `TestThrowingTask`, Linux). The `onDeviceChange` lambda in `flutter_webrtc_base.cc` checks the `alive` flag
before it touches `task_runner_`, which is gone once the object is destroyed. `PostEvent` stays one enqueue per event: the posted task calls the sink directly, so each event is
delivered once. Test: `hubbub_test/task_runner_test.cc` (real runner; watchdog turns a hang into a failure).

| Path | Change |
|---|---|
| `common/cpp/include/hubbub_audio.h`, `common/cpp/src/hubbub_audio.cc` | new: pipeline, resampler, limiter, meter (no libwebrtc dependency) |
| `common/cpp/include/hubbub_capture_processor.h` | new: `RTCAudioProcessing::CustomProcessing` adapter |
| `common/cpp/include/flutter_webrtc_base.h`, `common/cpp/src/flutter_webrtc_base.cc` | owns the processor, registers it in `EnsureWebRTCInitialized`, publisher thread for `hubbubLevels` and `hubbubLayout` events, `Shutdown()` (not unregister) in the destructor |
| `common/cpp/src/flutter_webrtc.cc` | method channel: `hubbubSetNoiseSuppression {mode: off\|webrtc\|rnnoise}`, `hubbubSetInputGain {gain: 0..2, finite}`, `hubbubGetStatus` (rate, channels, bands, frames, size, processed, skipped, skipReason) |
| `windows/CMakeLists.txt` (CRLF kept), `linux/CMakeLists.txt` | `add_subdirectory(../third_party/rnnoise)`, build `hubbub_audio.cc`, link `rnnoise` (Linux also `pthread`) |
| `third_party/rnnoise/` | new: RNNoise v0.2 (BSD-3-Clause, `COPYING`), own `CMakeLists.txt`; `src/rnnoise_data.c` is the upstream model, 29 MB of C arrays |
| `lib/src/hubbub_audio.dart`, `lib/flutter_webrtc.dart` | new `HubbubAudio` (setNoiseSuppression, setInputGain, status, levels, layout), exported |
| `windows/task_runner_windows.cc`, `linux/task_runner_linux.{h,cc}` | tasks run with the queue mutex released (see Threads); upstream re-entrant `EnqueueTask` deadlocked |
| `hubbub_test/` | native tests (`hubbub_audio_test`, `hubbub_processor_test`, `hubbub_tap_test`), the runtime probe (`apm_probe`) and `pulse_tone.c` (virtual tone microphone for Linux/WSLg) |
| `example/` | removed (1.4 MB, not needed; done in the pristine commit `24913d5`) |
| `third_party/rnnoise/CMakeLists.txt` | own file; for MSVC it defines `__SSE2__=1` (MSVC does not define it, RNNoise's x86 code selects its SSE paths with it) |
| `windows/CMakeLists.txt` | upstream is CRLF and stays CRLF; the diff against `24913d5` is the 6 added lines only |
| `app/pubspec.yaml` (outside the plugin) | `dependency_overrides: flutter_webrtc: path: ../third_party/flutter_webrtc`, and `pubspec.lock` now has `source: path` |

macOS, Android, iOS: untouched (the Dart API reports `HubbubAudio.supported == false` there).

## Wayland screen share: drop the cached Screen media list

`common/cpp/src/flutter_screen_capture.cc`, Linux only. On a Wayland portal session (`XDG_SESSION_TYPE`
is `wayland` and `WAYLAND_DISPLAY` is set, libwebrtc's own rule for choosing PipeWire) the Screen
capturer is the xdg-desktop-portal one, and creating the cached Screen media list starts a portal
session, which is GNOME's share prompt. Upstream keeps that list for the life of the plugin, so GNOME's
"sharing" indicator never closed and a second share reused the session without asking.

`GetDisplayMedia` now clears `sources_` and erases `medialist_[kScreen]` right after it has created and
started the real capturer (which reuses the list's restore token, so the user is asked once). The next
`getSources` builds a fresh list, which opens a new portal session with a new placeholder id, so a
fresh prompt appears.

Lifetime check (libwebrtc.m150.7871.03 wrapper): `MediaSourceImpl` keeps a raw `RTCDesktopMediaListImpl*`
used only by `UpdateThumbnail()`, which the plugin reaches only through `sources_` (cleared in the same
step). `RTCDesktopCapturerImpl` holds a `scoped_refptr<MediaSource>` for `source()` and never calls
`UpdateThumbnail()`, so dropping the list while the capture runs is safe. The list's destructor stops its
own thread and capturer, which closes only the list's portal session.

### Fix round 1: every attempt starts fresh, nothing is left behind

Review findings C1/C2/I1. Still Linux plus `IsWaylandPortalSession()` only; Windows, macOS and X11 take the
same paths as before (the new helper does nothing there).

- `GetDesktopSources` (the `getDesktopSources` call) drops the cached Screen list before building when the
  request includes `screen`. A list whose portal session was cancelled or failed never recovers (its
  capturer is permanently failed), so reusing it meant no prompt ever again. Only here: `UpdateDesktopSources`
  and the thumbnail path keep the list they have.
- New method-channel call `hubbubReleasePortalScreen` (`ReleasePortalScreen`, dispatched in
  `flutter_webrtc.cc`) drops the cached Screen list and its Screen entries in `sources_`. Destroying the list
  closes its portal session, so GNOME's dialog closes. The app calls it on cancel, timeout and error.
- `GetDisplayMedia`: in a portal session an unknown id fails with "source not found!" and no longer runs the
  Linux rebuild fallback (which started a new capturer, opened a surprise prompt and left a live session
  cached). The "source not found" and "CreateDesktopCapturer failed" paths also drop the list.
- All drops go through `DropPortalScreen()`, so the lifetime reasoning above covers them.

## Video frame rate fixes (2026-10-19)

Measured with `app/integration_test/video_fps_test.dart` (4K monitor, C920, local LiveKit, E2EE).

- **`RtpSenderSetParameters` now changes anything** (`common/cpp/src/flutter_peerconnection.cc`,
  `updateRtpParameters`). Three bugs hid each other. The encodings the wrapper hands back are
  copies, so the setters never reached the parameters: `set_encodings` writes them back. The
  `ssrc` Dart sends back is 0 (the sender owns it and it is read-only), and writing it made
  libwebrtc reject every change as a modified SSRC, so it is no longer written. `getParameters`
  also reports `rid` now.
  Follow-ups (2026-10-19, B2): a Dart encoding is matched to the sender's encoding by `rid` when it
  has one and the sender has that rid, otherwise by position (when either side has no rids). An
  encoding that matches nothing, or matches an already used one, makes the function return null and
  `RtpSenderSetParameters` answers `result: false`; nothing is dropped silently. Every refusal is
  written to stderr (`WARNING hubbub: setParameters refused: ...`) with the unmatched or doubly
  matched encoding and both rid lists. The `rid` is never
  written (fixed once the sender exists). A field is written only when it differs from what the
  sender reports: `active`, `maxBitrate`, `minBitrate`, `maxFramerate`, `scaleResolutionDownBy`,
  `priority`, `networkPriority`. `numTemporalLayers` and `scalabilityMode` are not reported by
  `getParameters`, so Dart's default `numTemporalLayers: 1` and an empty `scalabilityMode` are not
  requests: only a `numTemporalLayers` above 1, or a non-empty `scalabilityMode`, that differs from
  the sender is written. Effect: `scaleResolutionDownBy`
  and `active` updates after publish take effect (a 4K share's layers went from 3840x2160 /
  2560x1440 / 1280x720 at 16-27 fps to 1920x1080 / 1280x720 / 640x360 at 30-36 fps).
- **getUserMedia constraints** (`common/cpp/src/flutter_media_stream.cc`, `getConstrainInt`;
  macOS `FlutterRTCMediaStream.m`, unbuilt): width, height and frameRate accept a number or a map
  of `exact`, `ideal`, `max`, `min`. exact, ideal and max are the target (in that order), min only
  when none is given. Behaviour change for width and height: `max` (and `ideal`) now set the
  requested capture size, where only a plain number, `minWidth`/`minHeight` or the mandatory map
  did before. A fraction such as `0.5` counts as 1, and a width, height or frameRate below 1 (such
  as `{exact: 0}`) falls back to the default (1280x720, 30 fps), so fps 0 never reaches the
  capturer. LiveKit sends `frameRate: {max: N}`, which was ignored, so the capture fell
  back to `DEFAULT_FPS` and the C920 delivered 15 fps at 1280x720; it now delivers 30. macOS also
  stops `selectFpsForFormat` returning 0 when there is no target (`CMTimeMake(1, 0)`).
- **Tried and dropped:** the field trial `WebRTC-VideoEncoderSettings/encoder_thread_limit:N/`.
  It is a cap on the cores the encoders are told about, not a way to add threads, and made no
  difference (16 cores, OpenH264 already gets 8 threads at 4K).

## Keep full frame rate in low light (Windows, 2026-10-19)

A C920 with DirectShow `KSPROPERTY_CAMERACONTROL_AUTO_EXPOSURE_PRIORITY` = 1 (its default) captures
at 15 fps in a dark room; with 0 it captures at 30. New files `windows/hubbub_camera.cc` and
`common/cpp/include/hubbub_camera.h` (`strmiids.lib`, `oleaut32.lib` added to `windows/CMakeLists.txt`).

- Method `hubbubSetLowLightFullFrameRate {on: bool}` (flutter_webrtc.cc), Dart
  `HubbubCamera.setLowLightFullFrameRate`. On by default. A change applies at the next camera start,
  not to a camera that already runs.
- `GetUserVideo` (flutter_media_stream.cc), before `RTCVideoDevice::Create`: find the DirectShow
  device whose `DevicePath` moniker property equals the guid libwebrtc lists it by (stable across
  hot-plug, unlike name plus ordinal; a device without a `DevicePath` is matched by `FriendlyName`),
  read the priority through `IKsPropertySet`, and when it is 1 set it to 0. The filter is opened
  only for the get or set and released at once; the capture is never held open or touched. A
  camera without the control (the get fails) or with a value other than 1 is left alone.
- The original is restored when the track's capturer stops (`MediaStreamDispose`,
  `MediaStreamTrackDispose`), when `Create` fails (a failed first `Create` ends its use before the
  fallback to device 0 begins another), and in the `FlutterWebRTCBase` destructor. Users of one
  device are counted.
- App quit: Dart `exit(0)` runs no destructors, so `PluginAppShell.exitApp` (and the session-end
  handler for logoff and shutdown) first calls `hubbubRestoreCameraExposure`
  (`HubbubCamera.restoreExposure`, 2 s timeout), which runs `CameraExposureRestoreAll`.
- Crash safety: before the change, `HKCU\Software\Hubbub\CameraExposureRestore\<DevicePath>` =
  `<original>;<pid>;<process creation time>` is written. The first `hubbubSetLowLightFullFrameRate`
  call (or camera start) of the next run restores records whose process is gone (and only if the
  value is still 0), then deletes them. The creation time tells a reused pid from the Hubbub that
  wrote the record; an access-denied `OpenProcess` (an elevated Hubbub) counts as alive.
- Locking: `g_mu` guards only the maps; device enumeration and COM calls run outside it.
- Known limit: two Hubbub instances on one camera. The second sees 0 and leaves it alone, and the
  first restores 1 on its quit. The runner is single-instance per `HUBBUB_ROOT`, so this needs two
  roots. Also, a begin for a camera in the instant between another capture's last stop and its
  restore can read 0 and leave it, then see it restored to 1.
- Constraint numbers: NaN, infinity and values beyond int range count as missing (the default).
- Not unit tested (C++ has no test setup here): covered by the harness
  `app/integration_test/video_fps_test.dart` (priority 0 while running, 1 after stop, quit path,
  dynacast paused layers) and manual runs. The crash-recovery path was not run live.

## Diagnostic audio taps (2026-10-19, measurement only)

Off by default and zero cost when off (a relaxed atomic load per 10 ms block); no audio processing changed.
Written for "my voice sounds muffled / cuts off at the end": record both sides and compare
(`tools/audio_compare.py`, `app/integration_test/audio_quality_test.dart`, the app's Settings > Voice >
Advanced recorder). New files: `common/cpp/include/hubbub_tap.h` (`WavTap`, `WavInject`),
`hubbub_track_tap.h`, `hubbub_render_processor.h`; Dart `HubbubTaps` in `lib/src/hubbub_audio.dart`;
native test `hubbub_test/hubbub_tap_test.cc`.

- **WavTap**: the audio thread copies samples into a 4 MiB lock-free ring; a writer thread downmixes,
  resamples to 48 kHz mono 16-bit and writes the WAV (header fixed every second and at stop). Capped at
  10 minutes, ring overflow is counted (`droppedChunks`), per-tap `maxGapMs` shows a stalled clock.
- **What I send** (`hubbubTapStart/Stop {kind}`): `sendProcessed` is the buffer leaving the capture hook
  (after RNNoise, gain, limiter), which is what the engine resamples to 48 kHz and hands to Opus; `sendInput`
  is the buffer as the hook receives it. Both are at the APM rate (16 kHz on Windows), so the 48 kHz file has
  a bandwidth of at most 8 kHz by construction. `sourceRate` in the result says so.
- **Raw microphone: not reachable.** The hook sits after the APM's echo cancellation, noise suppression and AGC,
  and the wrapper has no custom audio device module. An `AddSink` on the local mic track delivers the processed
  signal, not the raw one (measured: identical to `sendProcessed`).
- **What I hear**: `hubbubRecordTrack {trackId, path}` / `hubbubStopRecordTrack` use `RTCAudioTrack::AddSink` on any
  track (remote: decoded audio of one participant, 48 kHz, after NetEq and the per-track volume). The final playout
  mix is available through `hubbubPlayout {action: tapStart|tapStop}` at the render pre-processing hook (16 kHz,
  2 channels on this PC). That hook is registered with the engine only by the first `hubbubPlayout` call and never
  unregistered (same crash as above); until then the render path is untouched.
- **Stop all** (`hubbubTapStopAll`): stops both send taps, every track tap and the playout tap (never registers the
  render hook); safe when idle. The app calls it after the per-tap stops, so a failed stop cannot leave a tap writing.
- **Tap lifetime**: `RemoveSink` is only declared in the closed wrapper (`rtc_audio_track.h`), so whether it waits for an
  `OnData` in flight is unconfirmed. Stopped `TrackTap`s are therefore moved to `hubbub_retired_track_taps_` (ring freed,
  a few bytes each) and destroyed only when the plugin is disposed.
- **Inject** (`hubbubInject {action: load|play|stop, path}`, test only): replaces the buffer at the start of the
  hook (silence after `load`, the file after `play`). It is after the APM stages, so the engine's own NS/AGC cannot
  be exercised by it; RNNoise, gain, limiter, the hook's sample rate, Opus, E2EE and the SFU are.
- **Test-only playout mute** (`hubbubPlayout {action: mute, on}`): zeroes the playout mix at the render hook after the
  per-track sinks, so a harness can receive audio without playing it (checked with `tools/output-peak.ps1`, which shows
  no audio session of the test process).
- Debug builds: `third_party/rnnoise/CMakeLists.txt` and `windows/CMakeLists.txt` now drop `/RTC1 /Od /Ob0` and
  optimise RNNoise and `hubbub_audio.cc` also in Debug. Unoptimised, RNNoise ran at about 85 % of real time on the
  capture thread, and a Debug test run delivered late, stuttering audio (delay growing to 5 s, 13 dropouts); optimised
  it is real time (83 ms delay, no dropouts). Release builds are unchanged.

## Re-applying on an upgrade (new flutter_webrtc version)

1. Copy the new pub.dev package over `third_party/flutter_webrtc` in a pristine commit (keep
   `third_party/.gitattributes`; delete `example/`, `third_party/downloads`, `third_party/libwebrtc`).
2. `git diff 24913d5 -- third_party/flutter_webrtc` (all patches so far) and apply with
   `git apply --3way`, or by hand using the table above. The edits in shared upstream files are
   small: two lines plus a block in `flutter_webrtc_base.cc` and `.h`, one `else if` block in
   `flutter_webrtc.cc`, three lines in each CMake file, one export in `flutter_webrtc.dart`.
3. Check the libwebrtc header `third_party/libwebrtc/include/rtc_audio_processing.h` still has
   `SetCapturePostProcessing`, then run the proof (below).
4. Keep `livekit_client`'s pin in step: it pins `flutter_webrtc` exactly.

## Build and test

Windows (cmd.exe, VS Build Tools 2022 x64 environment):

    cmake -S third_party/flutter_webrtc/hubbub_test -B target/hubbub_test -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build target/hubbub_test
    target\hubbub_test\hubbub_audio_test.exe       # DSP tests, ALL PASSED
    target\hubbub_test\hubbub_processor_test.exe   # adapter layouts, threads, shutdown; ALL PASSED
    target\hubbub_test\task_runner_test.exe       # real TaskRunnerWindows (message pump); Linux builds it against GLib
    target\hubbub_test\apm_probe.exe real          # needs a microphone; prints "hubbub: probe ..." lines

Debug runtime (iterator checks, debug heap) for the thread tests: configure another directory with
`-DCMAKE_BUILD_TYPE=Release -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebugDLL` (the RNNoise CMake forces `/O2`,
which a full Debug configuration rejects together with `/RTC1`).

Linux (WSL or a Linux box; `apm_probe` also needs `third_party/libwebrtc/lib/libwebrtc.so`, which
the first plugin build downloads, or pass `-DLIBWEBRTC_DIR=<extracted libwebrtc-linux-x64-release/linux-x64-release>`):

    cmake -S third_party/flutter_webrtc/hubbub_test -B /tmp/hubbub_test -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/hubbub_test
    /tmp/hubbub_test/hubbub_audio_test && /tmp/hubbub_test/hubbub_processor_test
    # a known tone through the real PulseAudio capture path (WSLg works):
    #   gcc hubbub_test/pulse_tone.c -o /tmp/pulse_tone -lpulse -lpulse-simple -lm
    #   PULSE_SERVER=unix:/mnt/wslg/PulseServer /tmp/pulse_tone 15 &   # makes the source "hubmic"
    #   PROBE_NOAPM=1 PROBE_DEVNAME=hubmic /tmp/hubbub_test/apm_probe count

`apm_probe` modes: `count` (count calls, log the layout of the first calls and the 1 kHz / 10 kHz tone
amplitudes at 32 kHz and above), `zero` (zero the buffer), `real` (the real pipeline with RNNoise and
gain 1.5, polling the levels slot), `teardown` (five times: swap in a new processor under load, make
the old one inert, destroy it), `unregister-null` (calls `SetCapturePostProcessing(nullptr)`; expected to
crash, see above). Environment: `PROBE_LOG=1` (libwebrtc log), `PROBE_SDP=1`, `PROBE_STEREO=1` (asks for stereo
Opus), `PROBE_NOAPM=1` (AEC/NS/AGC off), `PROBE_DEV=<n>` / `PROBE_DEVNAME=<text>` (recording device). It builds two peer connections in one process because the microphone
only starts once a send stream exists, and the Windows built-in AEC refuses to start capture before
playout, so the offerer sends a custom source first.

## Licences

flutter_webrtc: MIT (`LICENSE`). RNNoise: BSD-3-Clause, Copyright Jean-Marc Valin, Amazon, Mozilla,
Xiph.Org Foundation, Mark Borgerding (`third_party/rnnoise/COPYING`). libwebrtc prebuilt wrapper: MIT
(webrtc-sdk/libwebrtc, shipped with the download as `third_party/libwebrtc/LICENSE`; the WebRTC code inside is BSD-3).
