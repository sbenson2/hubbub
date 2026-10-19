// Unit tests for the Hubbub capture pipeline (no libwebrtc needed).
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "hubbub_audio.h"

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

using namespace hubbub;

static std::vector<float> Sine(int rate, double hz, double amp, int n,
                               int start = 0) {
  std::vector<float> v(n);
  for (int i = 0; i < n; ++i)
    v[i] = (float)(amp * std::sin(2 * M_PI * hz * (start + i) / rate));
  return v;
}
static float Peak(const std::vector<float>& v, size_t from = 0) {
  float p = 0;
  for (size_t i = from; i < v.size(); ++i) p = std::fmax(p, std::fabs(v[i]));
  return p;
}
static double Rms(const std::vector<float>& v, size_t from = 0) {
  double s = 0;
  for (size_t i = from; i < v.size(); ++i) s += (double)v[i] * v[i];
  return std::sqrt(s / std::max<size_t>(1, v.size() - from));
}

static void TestRechunker() {
  std::printf("rechunker: odd sizes -> 480 frames -> back\n");
  FrameRechunker r(480);
  std::vector<float> in(5000);
  for (size_t i = 0; i < in.size(); ++i) in[i] = (float)i;
  std::vector<float> got;
  int frames = 0;
  size_t pos = 0;
  const int sizes[] = {1, 7, 441, 480, 513, 3, 1000, 17};
  int si = 0;
  while (pos < in.size()) {
    size_t n = std::min<size_t>(sizes[si++ % 8], in.size() - pos);
    r.Push(in.data() + pos, n, [&](const float* f) {
      ++frames;
      got.insert(got.end(), f, f + 480);
    });
    pos += n;
  }
  CHECK(frames == 5000 / 480, "frames=%d", frames);
  CHECK(got.size() == (size_t)frames * 480, "size=%zu", got.size());
  bool same = true;
  for (size_t i = 0; i < got.size(); ++i) same &= got[i] == (float)i;
  CHECK(same, "order preserved");
  CHECK(r.Pending() == 5000 % 480, "pending=%zu", r.Pending());
}

static void TestSoftLimit() {
  std::printf("limiter: no sample exceeds full scale\n");
  float worst = 0;
  for (float x = -200000; x <= 200000; x += 37.5f)
    worst = std::fmax(worst, std::fabs(SoftLimit(x)));
  CHECK(worst < 32768.f, "worst=%f", worst);
  CHECK(SoftLimit(1000.f) == 1000.f, "identity below knee");
  CHECK(SoftLimit(-1000.f) == -1000.f, "identity below knee (neg)");
  float prev = -1;
  bool mono = true;
  for (float x = 0; x < 100000; x += 10) {
    float y = SoftLimit(x);
    mono &= y >= prev;
    prev = y;
  }
  CHECK(mono, "monotonic");
}

static std::vector<float> RunPipeline(CapturePipeline& p, std::vector<float> in,
                                      int block) {
  for (size_t i = 0; i + block <= in.size(); i += block)
    p.Process(in.data() + i, block);
  return in;
}

static void TestGain() {
  std::printf("gain: scaling, mute and 200%% on full scale\n");
  {
    CapturePipeline p;
    p.Initialize(48000, 1);
    p.SetGain(0.5f);
    auto in = Sine(48000, 440, 8000, 48000);
    auto out = RunPipeline(p, in, 480);
    // after the ramp settles the output is half the input
    double ratio = Rms(out, 4800) / Rms(in, 4800);
    CHECK(std::fabs(ratio - 0.5) < 0.01, "ratio=%f", ratio);
  }
  {
    CapturePipeline p;
    p.Initialize(48000, 1);
    p.SetGain(0.f);
    auto out = RunPipeline(p, Sine(48000, 440, 8000, 9600), 480);
    CHECK(Peak(out, 480) == 0.f, "muted peak=%f", Peak(out, 480));
  }
  {
    CapturePipeline p;
    p.Initialize(48000, 1);
    p.SetGain(2.f);
    // full-scale sine and a full-scale square
    auto sine = RunPipeline(p, Sine(48000, 1000, 32767, 48000), 480);
    CHECK(Peak(sine) <= 32767.f, "sine peak=%f", Peak(sine));
    CHECK(Peak(sine) > 30000.f, "sine still loud, peak=%f", Peak(sine));
    std::vector<float> sq(48000);
    for (size_t i = 0; i < sq.size(); ++i) sq[i] = (i / 24) % 2 ? 32767.f : -32768.f;
    auto sqo = RunPipeline(p, sq, 480);
    CHECK(Peak(sqo) <= 32767.f, "square peak=%f", Peak(sqo));
  }
  {
    CapturePipeline p;
    p.Initialize(48000, 1);
    p.SetGain(1.f);
    auto in = Sine(48000, 440, 8000, 9600);
    auto out = RunPipeline(p, in, 480);
    bool same = true;
    for (size_t i = 0; i < in.size(); ++i) same &= out[i] == in[i];
    CHECK(same, "gain 1.0 and rnnoise off is bit exact");
  }
}

static void TestPeaks() {
  std::printf("meter: pre/post peaks, about 20 per second\n");
  CapturePipeline p;
  p.Initialize(48000, 1);
  p.SetGain(1.5f);
  std::vector<Levels> got;
  p.SetLevelsCallback([&](const Levels& l) { got.push_back(l); });
  std::vector<float> in(48000);
  for (size_t i = 0; i < in.size(); ++i) in[i] = (i / 50) % 2 ? 16384.f : -16384.f;
  RunPipeline(p, in, 480);
  CHECK(got.size() >= 19 && got.size() <= 21, "callbacks=%zu", got.size());
  if (got.size() > 3) {
    const Levels& l = got[3];
    CHECK(std::fabs(l.pre - 0.5f) < 0.001f, "pre=%f", l.pre);
    CHECK(std::fabs(l.post - 0.75f) < 0.001f, "post=%f", l.post);
    CHECK(l.speech < 0.f, "speech=%f (no rnnoise)", l.speech);
  }
  // true pre-gain peak reaches full scale even when the gain is small
  CapturePipeline q;
  q.Initialize(48000, 1);
  q.SetGain(0.2f);
  std::vector<Levels> g2;
  q.SetLevelsCallback([&](const Levels& l) { g2.push_back(l); });
  std::vector<float> hot(4800, 32767.f);
  RunPipeline(q, hot, 480);
  CHECK(!g2.empty() && g2.back().pre >= 0.999f, "pre=%f", g2.empty() ? -1.f : g2.back().pre);
  CHECK(!g2.empty() && g2.back().post < 0.25f, "post=%f", g2.empty() ? -1.f : g2.back().post);
  CHECK(!g2.empty() && g2.back().clip == 1.f, "clip=%f", g2.empty() ? -1.f : g2.back().clip);
}

static void TestClipFraction() {
  std::printf("meter: clip is the fraction of blocks whose pre-gain peak is >= 0.98\n");
  CapturePipeline p;
  p.Initialize(48000, 1);
  std::vector<Levels> got;
  p.SetLevelsCallback([&](const Levels& l) { got.push_back(l); });
  // 48 kHz: 480-sample blocks, 5 blocks per 50 ms window. One hot block in each
  // window, the rest at half scale.
  std::vector<float> in(48000, 16000.f);
  for (size_t w = 0; w < 20; ++w)
    for (size_t i = 0; i < 480; ++i) in[w * 2400 + 960 + i] = 32500.f;  // block 2
  RunPipeline(p, in, 480);
  CHECK(got.size() >= 19, "windows=%zu", got.size());
  for (const Levels& l : got) CHECK(std::fabs(l.clip - 0.2f) < 1e-4f, "clip=%f", l.clip);
  // 0.97 of full scale does not count
  CapturePipeline q;
  q.Initialize(48000, 1);
  std::vector<Levels> g2;
  q.SetLevelsCallback([&](const Levels& l) { g2.push_back(l); });
  std::vector<float> warm(4800, 0.97f * 32768.f);
  RunPipeline(q, warm, 480);
  CHECK(!g2.empty() && g2.back().clip == 0.f, "clip=%f", g2.empty() ? -1.f : g2.back().clip);
}

static void TestResampler() {
  std::printf("resampler: 16k -> 48k -> 16k keeps level and shape\n");
  RationalResampler up(16000, 48000), down(48000, 16000);
  auto in = Sine(16000, 1000, 10000, 16000);
  std::vector<float> mid, out;
  up.Process(in.data(), in.size(), mid);
  CHECK(mid.size() > 47000 && mid.size() <= 48000, "mid=%zu", mid.size());
  down.Process(mid.data(), mid.size(), out);
  CHECK(out.size() > 15000, "out=%zu", out.size());
  double ratio = Rms(out, 2000) / Rms(in, 2000);
  CHECK(std::fabs(ratio - 1.0) < 0.02, "rms ratio=%f", ratio);
  // 7 kHz tone below the cutoff survives, a 9 kHz tone at 32k -> 48k does not alias
  RationalResampler r32(32000, 48000);
  auto in32 = Sine(32000, 3000, 10000, 32000);
  std::vector<float> o32;
  r32.Process(in32.data(), in32.size(), o32);
  CHECK(std::fabs(Rms(o32, 3000) - 10000 / std::sqrt(2.0)) < 200, "32k rms=%f", Rms(o32, 3000));
}

static void TestRnnoise(int rate) {
  std::printf("rnnoise: %d Hz suppresses steady noise, block-size preserving\n", rate);
  CapturePipeline p;
  p.Initialize(rate, 1);
  p.SetRnnoiseEnabled(true);
  std::vector<Levels> got;
  p.SetLevelsCallback([&](const Levels& l) { got.push_back(l); });
  std::mt19937 rng(1);
  std::normal_distribution<float> nd(0.f, 800.f);
  const int block = rate / 100;
  std::vector<float> in(rate * 4);
  for (auto& s : in) s = nd(rng);
  auto out = RunPipeline(p, in, block);
  double before = Rms(in, rate * 2), after = Rms(out, rate * 2);
  CHECK(after < before * 0.5, "before=%f after=%f", before, after);
  CHECK(!got.empty() && got.back().speech >= 0.f && got.back().speech <= 1.f,
        "speech=%f", got.empty() ? -2.f : got.back().speech);
  CHECK(Peak(out) <= 32767.f, "peak");
  // switching off returns to bit exact pass through
  p.SetRnnoiseEnabled(false);
  auto in2 = Sine(rate, 440, 8000, rate / 2);
  auto out2 = RunPipeline(p, in2, block);
  bool same = true;
  for (size_t i = block; i < in2.size(); ++i) same &= out2[i] == in2[i];
  CHECK(same, "pass through after switching off");
}

static void TestSpeechLike() {
  std::printf("rnnoise: 48 kHz tone burst passes through\n");
  CapturePipeline p;
  p.Initialize(48000, 1);
  p.SetRnnoiseEnabled(true);
  auto in = Sine(48000, 300, 6000, 48000);
  // harmonic-rich voiced stand-in: 5 harmonics
  for (int h = 2; h <= 6; ++h) {
    auto s = Sine(48000, 300.0 * h, 6000.0 / h, 48000);
    for (size_t i = 0; i < in.size(); ++i) in[i] += s[i];
  }
  auto out = RunPipeline(p, in, 480);
  CHECK(Rms(out, 24000) > 0.0, "output finite");
  for (float v : out) CHECK(std::isfinite(v), "finite");
}

static void Benchmark() {
  CapturePipeline p;
  p.Initialize(48000, 1);
  p.SetRnnoiseEnabled(true);
  std::vector<float> in = Sine(48000, 440, 5000, 480 * 1000);
  auto t0 = std::chrono::steady_clock::now();
  RunPipeline(p, in, 480);
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("benchmark: 1000 RNNoise frames (10 s of audio) in %.3f s -> %.0f frames/s, %.2f%% of one core at real time\n",
              s, 1000 / s, 100.0 * s / 10.0);
}

int main() {
  TestRechunker();
  TestSoftLimit();
  TestGain();
  TestPeaks();
  TestClipFraction();
  TestResampler();
  TestRnnoise(48000);
  TestRnnoise(16000);
  TestRnnoise(32000);
  TestSpeechLike();
  Benchmark();
  std::printf(g_fail ? "FAILED: %d check(s)\n" : "ALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
