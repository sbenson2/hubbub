// Tests for the libwebrtc adapter (hubbub_capture_processor.h) with the buffer
// layouts libwebrtc has been seen to use, odd layouts, shutdown, and setters
// racing the audio thread. Needs only libwebrtc's headers (no library).
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "hubbub_capture_processor.h"

static int g_fail = 0;
#define CHECK(cond, ...)                                              \
  do {                                                                \
    if (!(cond)) {                                                    \
      ++g_fail;                                                       \
      std::printf("  FAIL %s:%d  %s  ", __FILE__, __LINE__, #cond);   \
      std::printf(__VA_ARGS__);                                       \
      std::printf("\n");                                              \
    }                                                                 \
  } while (0)

using hubbub::CaptureProcessor;

static std::vector<float> Tone(int n, double hz, double rate, double amp) {
  std::vector<float> v(n);
  for (int i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2 * M_PI * hz * i / rate));
  return v;
}
static bool Scaled(const std::vector<float>& out, const std::vector<float>& in, float k) {
  for (size_t i = 0; i < in.size(); ++i)
    if (std::fabs(out[i] - in[i] * k) > 1e-3f * std::fmax(1.f, std::fabs(in[i]))) return false;
  return true;
}
static bool Same(const std::vector<float>& a, const std::vector<float>& b) { return a == b; }

// A pipeline settles its gain ramp within the first block, so feed one block
// first and look at the second.
static void Warm(CaptureProcessor& p, int bands, int frames, int size, int channels) {
  std::vector<float> b((size_t)(std::max)(size, frames * channels), 1000.f);
  p.Process(bands, frames, size, b.data());
}

static void TestWindowsLayout() {
  std::printf("layout seen on Windows: 16 kHz, mono, 1 band, 160 frames\n");
  CaptureProcessor p;
  p.SetGain(0.5f);
  p.Initialize(16000, 1);
  Warm(p, 1, 160, 160, 1);
  auto in = Tone(160, 440, 16000, 8000);
  auto buf = in;
  p.Process(1, 160, 160, buf.data());
  CHECK(Scaled(buf, in, 0.5f), "gain reaches the buffer");
  CHECK(p.processed() == 2 && p.skipped() == 0, "processed=%ld skipped=%ld", p.processed(), p.skipped());
  CHECK(p.rate() == 16000 && p.channels() == 1 && p.last_bands() == 1 && p.last_frames() == 160, "status");
}

static void TestLinuxLayout() {
  std::printf("layout seen on Linux: 48 kHz, mono, 3 bands but 480 frames of full-band audio\n");
  CaptureProcessor p;
  p.SetGain(0.5f);
  p.Initialize(48000, 1);
  Warm(p, 3, 480, 480, 1);
  // a 10 kHz tone is above the first band (0 to 8 kHz): it must be processed too
  auto in = Tone(480, 10000, 48000, 6000);
  auto buf = in;
  p.Process(3, 480, 480, buf.data());
  CHECK(Scaled(buf, in, 0.5f), "the whole 480-sample block, 10 kHz included, is processed");
  CHECK(p.skipped() == 0 && p.processed() == 2, "processed=%ld skipped=%ld", p.processed(), p.skipped());
}

static void TestStereo() {
  std::printf("two channels, planar (Initialize says 2)\n");
  CaptureProcessor p;
  p.SetGain(0.5f);
  p.Initialize(48000, 2);
  std::vector<float> warm(960, 1000.f);
  p.Process(3, 480, 960, warm.data());
  auto l = Tone(480, 440, 48000, 8000), r = Tone(480, 1000, 48000, 4000);
  std::vector<float> buf(l);
  buf.insert(buf.end(), r.begin(), r.end());
  p.Process(3, 480, 960, buf.data());
  CHECK(Scaled(std::vector<float>(buf.begin(), buf.begin() + 480), l, 0.5f), "left");
  CHECK(Scaled(std::vector<float>(buf.begin() + 480, buf.end()), r, 0.5f), "right");

  // buffer_size claims one channel only: Initialize's count wins (and it is logged once)
  std::vector<float> buf2(960);
  for (size_t i = 0; i < buf2.size(); ++i) buf2[i] = 4000.f;
  p.Process(3, 480, 480, buf2.data());
  CHECK(buf2[0] == 2000.f && buf2[600] == 2000.f, "both channels processed: %f %f", buf2[0], buf2[600]);
  CHECK(p.skipped() == 0, "not skipped");
}

static void TestSkipsAreCounted() {
  std::printf("layouts we cannot process are passed through, counted and reported\n");
  CaptureProcessor p;
  p.SetGain(0.5f);
  std::vector<float> data(480, 1000.f), orig = data;
  p.Process(1, 160, 160, data.data());  // before Initialize
  CHECK(p.skipped() == 1 && p.last_skip_reason() == CaptureProcessor::kNoPipelines, "no pipelines");
  p.Initialize(48000, 1);
  p.Process(3, 160, 160, data.data());  // per-band frame count: bands stored apart
  CHECK(p.skipped() == 2 && p.last_skip_reason() == CaptureProcessor::kSplitBands, "split reason=%d", p.last_skip_reason());
  p.Process(1, 441, 441, data.data());  // not a 10 ms frame at all
  CHECK(p.skipped() == 3 && p.last_skip_reason() == CaptureProcessor::kBadFrames, "frames reason=%d", p.last_skip_reason());
  p.Process(1, 0, 0, data.data());
  CHECK(p.skipped() == 4 && p.last_skip_reason() == CaptureProcessor::kBadArguments, "args reason=%d", p.last_skip_reason());
  p.Process(1, 480, 480, nullptr);
  CHECK(p.skipped() == 5, "null buffer");
  CHECK(Same(data, orig), "skipped blocks are left untouched");
  CHECK(p.processed() == 0 && p.calls() == 5, "processed=%ld calls=%ld", p.processed(), p.calls());
  CHECK(std::string(CaptureProcessor::SkipName(p.last_skip_reason())) == "bad arguments", "name");
  p.Process(3, 480, 480, data.data());
  CHECK(p.processed() == 1, "a good block after the skips is processed");
}

static void TestResetAndRelease() {
  std::printf("Reset to a new rate, Release, Shutdown\n");
  CaptureProcessor p;
  p.SetGain(0.5f);
  p.Initialize(16000, 1);
  p.Reset(16000);
  CHECK(p.inits() == 1, "same rate: no re-init");
  p.Reset(48000);
  CHECK(p.rate() == 48000 && p.inits() == 2, "rate=%d", p.rate());
  std::vector<float> d(480, 1000.f);
  p.Process(3, 480, 480, d.data());
  CHECK(p.processed() == 1, "processes at the new rate");
  p.Release();
  p.Process(3, 480, 480, d.data());
  CHECK(p.skipped() == 1, "after Release blocks are counted as skipped");
  p.Initialize(48000, 1);
  p.Shutdown();
  long calls = p.calls();
  auto before = d;
  p.Process(3, 480, 480, d.data());
  p.Initialize(16000, 1);
  CHECK(p.calls() == calls && Same(d, before) && p.rate() == 48000, "inert after Shutdown");
}

static void TestGainValidation() {
  std::printf("gain: NaN and infinity are refused\n");
  CaptureProcessor p;
  CHECK(p.SetGain(1.25f) && p.gain() == 1.25f, "ok");
  CHECK(!p.SetGain(NAN) && !p.SetGain(INFINITY) && p.gain() == 1.25f, "refused, unchanged");
}

// Setters on another thread while the audio thread cycles through Initialize,
// Process, Reset and Release. Run under the MSVC debug runtime.
static void TestSettersRaceTheAudioThread() {
  std::printf("setters racing Initialize/Process/Reset/Release\n");
  hubbub::LogEnabled() = false;  // hundreds of Initialize calls
  CaptureProcessor p;
  std::atomic<bool> stop{false};
  std::atomic<long> setter_ops{0};
  std::thread setters([&] {
    std::mt19937 rng(7);
    std::uniform_real_distribution<float> g(0.f, 2.f);
    hubbub::Levels l;
    while (!stop.load()) {
      p.SetGain(g(rng));
      p.SetRnnoiseEnabled(rng() & 1);
      (void)p.gain();
      (void)p.rnnoise();
      (void)p.rate();
      (void)p.channels();
      (void)p.Layout();
      p.levels().Load(&l);
      ++setter_ops;
    }
  });
  std::mt19937 rng(3);
  std::normal_distribution<float> nd(0.f, 6000.f);
  long blocks = 0, bad = 0;
  const int rates[] = {16000, 32000, 48000};
  auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(2500);
  int cycle = 0;
  while (std::chrono::steady_clock::now() < end) {
    int rate = rates[cycle % 3];
    int ch = 1 + (cycle % 2);
    p.Initialize(rate, ch);
    const int frames = rate / 100;
    std::vector<float> buf((size_t)frames * ch);
    for (int b = 0; b < 60; ++b) {
      for (auto& v : buf) v = std::fmax(-32768.f, std::fmin(32767.f, nd(rng)));
      p.Process(rate == 16000 ? 1 : 3, frames, frames * ch, buf.data());
      ++blocks;
      for (float v : buf) bad += !(std::isfinite(v) && std::fabs(v) <= 32767.f);
      if (b == 20) p.Reset(rates[(cycle + 1) % 3]), p.Initialize(rate, ch);
    }
    if (cycle % 4 == 3) p.Release();
    ++cycle;
  }
  stop = true;
  setters.join();
  hubbub::LogEnabled() = true;
  CHECK(bad == 0, "%ld out-of-range or non-finite samples in %ld blocks", bad, blocks);
  CHECK(setter_ops.load() > 1000, "setter thread ran %ld operations", setter_ops.load());
  std::printf("  %ld blocks over %d init cycles, %ld setter operations\n", blocks, cycle, setter_ops.load());
}

// Shutdown waits for a Process that is running.
static void TestShutdownWaits() {
  std::printf("Shutdown waits for a block in flight\n");
  CaptureProcessor p;
  p.SetRnnoiseEnabled(true);
  p.Initialize(48000, 1);
  std::atomic<bool> running{true};
  std::atomic<long> after_shutdown_started{0};
  std::atomic<bool> shut{false};
  std::thread audio([&] {
    std::vector<float> buf(480, 3000.f);
    while (running.load()) {
      p.Process(3, 480, 480, buf.data());
      if (shut.load()) ++after_shutdown_started;
    }
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  long calls_before = p.calls();
  shut = true;
  p.Shutdown();
  long calls_at_shutdown = p.calls();
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  CHECK(calls_before > 0, "audio thread was running");
  CHECK(p.calls() == calls_at_shutdown, "no block is counted after Shutdown returned");
  running = false;
  audio.join();
}

int main() {
  TestWindowsLayout();
  TestLinuxLayout();
  TestStereo();
  TestSkipsAreCounted();
  TestResetAndRelease();
  TestGainValidation();
  TestSettersRaceTheAudioThread();
  TestShutdownWaits();
  std::printf(g_fail ? "FAILED: %d check(s)\n" : "ALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
