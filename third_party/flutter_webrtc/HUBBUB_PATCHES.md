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

| Path | Change |
|---|---|
| `common/cpp/include/hubbub_audio.h`, `common/cpp/src/hubbub_audio.cc` | new: pipeline, resampler, limiter, meter (no libwebrtc dependency) |
| `common/cpp/include/hubbub_capture_processor.h` | new: `RTCAudioProcessing::CustomProcessing` adapter |
| `common/cpp/include/flutter_webrtc_base.h`, `common/cpp/src/flutter_webrtc_base.cc` | owns the processor, registers it in `EnsureWebRTCInitialized`, publisher thread for `hubbubLevels` and `hubbubLayout` events, `Shutdown()` (not unregister) in the destructor |
| `common/cpp/src/flutter_webrtc.cc` | method channel: `hubbubSetNoiseSuppression {mode: off\|webrtc\|rnnoise}`, `hubbubSetInputGain {gain: 0..2, finite}`, `hubbubGetStatus` (rate, channels, bands, frames, size, processed, skipped, skipReason) |
| `windows/CMakeLists.txt` (CRLF kept), `linux/CMakeLists.txt` | `add_subdirectory(../third_party/rnnoise)`, build `hubbub_audio.cc`, link `rnnoise` (Linux also `pthread`) |
| `third_party/rnnoise/` | new: RNNoise v0.2 (BSD-3-Clause, `COPYING`), own `CMakeLists.txt`; `src/rnnoise_data.c` is the upstream model, 29 MB of C arrays |
| `lib/src/hubbub_audio.dart`, `lib/flutter_webrtc.dart` | new `HubbubAudio` (setNoiseSuppression, setInputGain, status, levels, layout), exported |
| `hubbub_test/` | native tests (`hubbub_audio_test`, `hubbub_processor_test`), the runtime probe (`apm_probe`) and `pulse_tone.c` (virtual tone microphone for Linux/WSLg) |
| `example/` | removed (1.4 MB, not needed; done in the pristine commit `24913d5`) |
| `third_party/rnnoise/CMakeLists.txt` | own file; for MSVC it defines `__SSE2__=1` (MSVC does not define it, RNNoise's x86 code selects its SSE paths with it) |
| `windows/CMakeLists.txt` | upstream is CRLF and stays CRLF; the diff against `24913d5` is the 6 added lines only |
| `app/pubspec.yaml` (outside the plugin) | `dependency_overrides: flutter_webrtc: path: ../third_party/flutter_webrtc`, and `pubspec.lock` now has `source: path` |

macOS, Android, iOS: untouched (the Dart API reports `HubbubAudio.supported == false` there).

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
