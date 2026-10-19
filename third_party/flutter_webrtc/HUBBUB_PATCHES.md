# Hubbub patches to flutter_webrtc 1.6.2+hotfix.4

Upstream: https://github.com/flutter-webrtc/flutter-webrtc (MIT, `LICENSE` kept). This is the
version livekit_client 2.13.1 pins. The app uses it through `dependency_overrides` in
`app/pubspec.yaml`.

Git history is the diff: commit `24913d5` is the pristine pub.dev package (minus `example/` and the
downloaded libwebrtc prebuilt); every later commit touching `third_party/flutter_webrtc` is a patch.
`git diff 24913d5 -- third_party/flutter_webrtc` shows all of them.

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

1. RNNoise (optional), at 48 kHz in 480 sample frames. The APM hands the processor mono floats in
   the 16-bit range at its internal rate (16 kHz seen; up to 32 kHz), so a windowed-sinc rational
   resampler brings the stream to 48 kHz and back (about 1 ms extra at 16/32 kHz, none at 48 kHz).
2. Input gain 0 to 2 (ramped across each block), then a soft limiter (tanh above 85 percent of full
   scale) so 200 percent cannot clip; exactly bit-transparent at gain 1.0 with RNNoise off.
3. Peak meter: pre-gain and post-gain peaks, RNNoise speech probability, and the share of 10 ms blocks
   whose pre-gain peak was at least 0.98, every 50 ms.

| Path | Change |
|---|---|
| `common/cpp/include/hubbub_audio.h`, `common/cpp/src/hubbub_audio.cc` | new: pipeline, resampler, limiter, meter (no libwebrtc dependency) |
| `common/cpp/include/hubbub_capture_processor.h` | new: `RTCAudioProcessing::CustomProcessing` adapter |
| `common/cpp/include/flutter_webrtc_base.h`, `common/cpp/src/flutter_webrtc_base.cc` | owns the processor, registers it in `EnsureWebRTCInitialized`, unregisters in the destructor, posts `hubbubLevels` events |
| `common/cpp/src/flutter_webrtc.cc` | method channel: `hubbubSetNoiseSuppression {mode: off\|webrtc\|rnnoise}`, `hubbubSetInputGain {gain: 0..2}`, `hubbubGetStatus` |
| `windows/CMakeLists.txt`, `linux/CMakeLists.txt` | `add_subdirectory(../third_party/rnnoise)`, build `hubbub_audio.cc`, link `rnnoise` |
| `third_party/rnnoise/` | new: RNNoise v0.2 (BSD-3-Clause, `COPYING`), own `CMakeLists.txt`; `src/rnnoise_data.c` is the upstream model, 29 MB of C arrays |
| `lib/src/hubbub_audio.dart`, `lib/flutter_webrtc.dart` | new `HubbubAudio` (setNoiseSuppression, setInputGain, status, levels), exported |
| `hubbub_test/` | native tests (`hubbub_audio_test`) and the runtime proof (`apm_probe`) |

macOS, Android, iOS: untouched (the Dart API reports `HubbubAudio.supported == false` there).

## Re-applying on an upgrade (new flutter_webrtc version)

1. Copy the new pub.dev package over `third_party/flutter_webrtc` in a pristine commit (keep
   `third_party/.gitattributes`; delete `example/`, `third_party/downloads`, `third_party/libwebrtc`).
2. `git diff 24913d5 HEAD~1 -- third_party/flutter_webrtc` (the old patches) and apply with
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
    target\hubbub_test\hubbub_audio_test.exe     # DSP tests, ALL PASSED
    target\hubbub_test\apm_probe.exe real        # needs a microphone; prints "hubbub: probe ..." lines

Linux (WSL or a Linux box; `apm_probe` also needs `third_party/libwebrtc/lib/libwebrtc.so`, which
the first plugin build downloads):

    cmake -S third_party/flutter_webrtc/hubbub_test -B /tmp/hubbub_test -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/hubbub_test --target hubbub_audio_test && /tmp/hubbub_test/hubbub_audio_test

`apm_probe` modes: `count` (count calls), `zero` (zero the buffer), `real` (the real pipeline with
RNNoise and gain 1.5). It builds two peer connections in one process because the microphone
only starts once a send stream exists, and the Windows built-in AEC refuses to start capture before
playout, so the offerer sends a custom source first.

## Licences

flutter_webrtc: MIT (`LICENSE`). RNNoise: BSD-3-Clause, Copyright Jean-Marc Valin, Amazon, Mozilla,
Xiph.Org Foundation, Mark Borgerding (`third_party/rnnoise/COPYING`). libwebrtc prebuilt wrapper: MIT
(webrtc-sdk/libwebrtc, shipped with the download as `third_party/libwebrtc/LICENSE`; the WebRTC code inside is BSD-3).
