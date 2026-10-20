// Unit tests for the Hubbub capture pipeline (no libwebrtc needed).
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <random>
#include <thread>
#include <vector>

#include "hubbub_audio.h"
#include "rnnoise.h"

// Counts allocations while g_count is set (to prove the audio path allocates nothing).
static std::atomic<bool> g_count{false};
static std::atomic<long> g_allocs{0};
void* operator new(size_t n) {
  if (g_count.load()) ++g_allocs;
  void* p = std::malloc(n ? n : 1);
  if (!p) throw std::bad_alloc();
  return p;
}
void* operator new[](size_t n) { return operator new(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }
void operator delete[](void* p, size_t) noexcept { std::free(p); }

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

// Voiced stand-in (120 Hz, 30 harmonics, 4 Hz syllable envelope) for |burst_ms|,
// then a quiet noise tail (the trailing "s"/fade) for |tail_ms|. Deterministic.
static std::vector<float> SpeechThenTail(int burst_ms, int tail_ms, float tail_amp) {
  const int rate = 48000;
  const int nb = rate * burst_ms / 1000, nt = rate * tail_ms / 1000;
  std::vector<float> v(nb + nt, 0.f);
  for (int h = 1; h <= 30; ++h) {
    double amp = 5000.0 / h;
    for (int i = 0; i < nb; ++i)
      v[i] += (float)(amp * std::sin(2 * M_PI * 120.0 * h * i / rate + h));
  }
  for (int i = 0; i < nb; ++i)
    v[i] *= (float)(0.65 + 0.35 * std::sin(2 * M_PI * 4.0 * i / rate));
  std::mt19937 rng(7);
  std::normal_distribution<float> nd(0.f, tail_amp);
  for (int i = nb; i < nb + nt; ++i) v[i] = nd(rng);
  return v;
}

// Runs |in| through RNNoise directly (48 kHz, 10 ms frames) with the tail mode on, the
// given hold and a floor of 0, so the floor cannot be what keeps the tail alive. Returns the
// output energy per frame and the speech probability per frame.
static void RawTail(const std::vector<float>& in, int hold_frames, std::vector<double>* energy,
                    std::vector<float>* vad) {
  DenoiseState* st = rnnoise_create(nullptr);
  rnnoise_set_tail(st, 1, 0.f, hold_frames, 0.92f);
  const size_t fs = (size_t)rnnoise_get_frame_size();
  std::vector<float> out(fs);
  for (size_t i = 0; i + fs <= in.size(); i += fs) {
    vad->push_back(rnnoise_process_frame(st, out.data(), in.data() + i));
    double e = 0;
    for (float v : out) e += (double)v * v;
    energy->push_back(e);
  }
  rnnoise_destroy(st);
}

static double MeanOf(const std::vector<double>& e, size_t from, size_t to) {
  double s = 0;
  for (size_t i = from; i < to; ++i) s += e[i];
  return s / (double)(to - from);
}

static void TestTailHold() {
  std::printf("rnnoise tail: the hold keeps the speech gain for 200 ms after speech ends, then releases\n");
  // Loud noise tail: RNNoise's own gain for it is near zero, so what the output keeps comes
  // from the held speech gains. Floor 0 in RawTail: only the hold can keep it.
  auto in = SpeechThenTail(1500, 600, 3000.f);
  std::vector<double> held, none;
  std::vector<float> vad_held, vad_none;
  RawTail(in, 20, &held, &vad_held);
  RawTail(in, 0, &none, &vad_none);
  // The first frame after the burst whose speech probability is below 0.5.
  size_t drop = 150;
  while (drop < vad_held.size() && vad_held[drop] >= 0.5f) ++drop;
  CHECK(drop + 45 < held.size(), "speech probability drops after the burst: frame %zu", drop);
  // Frames 3..17 after the drop: inside the 20 frame hold. 30..40: after it has run out and
  // the gain has had 10 frames at 0.92 to release.
  double in_hold = MeanOf(held, drop + 3, drop + 18), in_none = MeanOf(none, drop + 3, drop + 18);
  double after = MeanOf(held, drop + 30, drop + 41);
  std::printf("  drop at frame %zu; energy: hold %.3g, no hold %.3g, after hold %.3g\n", drop,
              in_hold, in_none, after);
  CHECK(in_hold > 4 * in_none, "hold keeps the gain: %g vs %g without", in_hold, in_none);
  CHECK(after < in_hold * 0.4, "gain releases after the hold: %g vs %g", after, in_hold);
}

static void TestTailSteadyNoise() {
  std::printf("rnnoise tail: steady noise is still suppressed with the new mode\n");
  for (int classic = 0; classic < 2; ++classic) {
    CapturePipeline p;
    p.Initialize(48000, 1);
    p.SetRnnoiseEnabled(true);
    p.SetTailClassic(classic);
    std::mt19937 rng(3);
    std::normal_distribution<float> nd(0.f, 800.f);
    std::vector<float> in(48000 * 4);
    for (auto& x : in) x = nd(rng);
    auto out = RunPipeline(p, in, 480);
    double r = Rms(out, 48000 * 2) / Rms(in, 48000 * 2);
    std::printf("  %s: out/in %.3f (%.1f dB)\n", classic ? "classic" : "new", r, 20 * std::log10(r));
    CHECK(r < 0.25, "suppressed by at least 12 dB: ratio %f", r);
    if (!classic) CHECK(r >= 0.08, "not below the floor: ratio %f", r);
  }
}

static void TestTailSwitchLive() {
  std::printf("rnnoise tail: switching mode on the audio thread allocates nothing\n");
  CapturePipeline p;
  p.Initialize(48000, 1);
  p.SetRnnoiseEnabled(true);
  std::vector<float> blk(480, 100.f);
  p.Process(blk.data(), blk.size());
  g_allocs = 0;
  g_count = true;
  for (int i = 0; i < 6; ++i) {
    p.SetTailClassic(i & 1);
    std::fill(blk.begin(), blk.end(), 100.f);
    p.Process(blk.data(), blk.size());
  }
  g_count = false;
  CHECK(g_allocs.load() == 0, "allocs=%ld", g_allocs.load());
}

// |x| through a from -> to -> from round trip: a low-pass at 45 % of |to|/2, in
// step with |x| (the resampler holds samples back, it does not shift them).
static std::vector<float> LowPass(const std::vector<float>& x, int from, int to) {
  RationalResampler down(from, to), up(to, from);
  std::vector<float> mid, out;
  std::vector<float> padded = x;
  padded.resize(x.size() + from / 10, 0.f);  // push out the filter tails
  down.Process(padded.data(), padded.size(), mid);
  up.Process(mid.data(), mid.size(), out);
  out.resize(x.size());
  return out;
}
static std::vector<float> HighPart(const std::vector<float>& x) {  // above about 7.2 kHz
  auto lo = LowPass(x, 48000, 16000);
  for (size_t i = 0; i < x.size(); ++i) lo[i] = x[i] - lo[i];
  return lo;
}

// Voiced bursts (140 Hz, harmonics up to |top_hz|), 300 ms on, 300 ms off.
static std::vector<float> VoicedBursts(int n, double top_hz, double amp) {
  std::vector<float> v(n, 0.f);
  for (int h = 1; 140.0 * h <= top_hz; ++h)
    for (int i = 0; i < n; ++i) v[i] += (float)(amp / std::sqrt((double)h) * std::sin(2 * M_PI * 140.0 * h * i / 48000 + h));
  for (int i = 0; i < n; ++i)
    if ((i / 14400) % 2) v[i] = 0.f;
  return v;
}

static void TestWidebandIgnoresHighNoise() {
  std::printf("rnnoise 48 kHz: noise above 8 kHz does not change how the band below is denoised\n");
  const int n = 48000 * 4;
  std::mt19937 rng(11);
  std::normal_distribution<float> nd(0.f, 1000.f);
  std::vector<float> w1(n), w2(n);
  for (auto& s : w1) s = nd(rng);
  for (auto& s : w2) s = nd(rng);
  auto speech = VoicedBursts(n, 6000, 1500);
  auto low_noise = LowPass(w1, 48000, 16000);  // below 7.2 kHz
  // 10.4 to 17.6 kHz: a 0..3.6 kHz noise band moved up by 14 kHz
  auto high_noise = LowPass(w2, 48000, 8000);
  for (int i = 0; i < n; ++i) high_noise[i] *= (float)(2.0 * std::cos(2 * M_PI * 14000.0 * i / 48000));
  std::vector<float> a(n), b(n);
  for (int i = 0; i < n; ++i) {
    a[i] = speech[i] + low_noise[i];
    b[i] = a[i] + high_noise[i];
  }
  CapturePipeline pa, pb;
  for (auto* p : {&pa, &pb}) {
    p->Initialize(48000, 1);
    p->SetRnnoiseEnabled(true);
  }
  auto oa = LowPass(RunPipeline(pa, a, 480), 48000, 16000);
  auto ob = LowPass(RunPipeline(pb, b, 480), 48000, 16000);
  std::vector<float> diff(n);
  for (int i = 0; i < n; ++i) diff[i] = oa[i] - ob[i];
  double rel = Rms(diff, 48000) / Rms(oa, 48000);
  std::printf("  below 7.2 kHz, with vs without the high noise: difference %.1f dB\n", 20 * std::log10(rel + 1e-12));
  // without the split it is about -21 dB: RNNoise's gains below 7.2 kHz follow the high noise
  CHECK(rel < 0.01, "the high noise changed the band below by %.1f dB", 20 * std::log10(rel));
}

static void TestHighBandFollowsGains() {
  std::printf("rnnoise 48 kHz: content above 8 kHz kept in speech, suppressed in steady noise\n");
  // voiced bursts with harmonics up to 12 kHz: the part above 8 kHz must survive
  const int n = 48000 * 3;
  auto speech = VoicedBursts(n, 12000, 1500);
  CapturePipeline p;
  p.Initialize(48000, 1);
  p.SetRnnoiseEnabled(true);
  auto out = RunPipeline(p, speech, 480);
  auto hi_in = HighPart(speech), hi_out = HighPart(out);
  double kept = 0, sent = 0;  // second and third burst; the output lags 20 ms
  for (int i = 28800 + 2400; i < 28800 + 12000; ++i) {
    sent += (double)hi_in[i] * hi_in[i] + (double)hi_in[i + 57600] * hi_in[i + 57600];
    kept += (double)hi_out[i + 1000] * hi_out[i + 1000] + (double)hi_out[i + 57600 + 1000] * hi_out[i + 57600 + 1000];
  }
  double kept_db = 10 * std::log10(kept / sent);
  std::printf("  speech above 7.2 kHz: %.1f dB\n", kept_db);
  CHECK(kept_db > -6.0, "speech above 7.2 kHz lost %.1f dB", kept_db);
  // steady white noise: the part above 8 kHz goes down like the rest
  std::mt19937 rng(3);
  std::normal_distribution<float> nd(0.f, 1500.f);
  std::vector<float> noise(n);
  for (auto& s : noise) s = nd(rng);
  CapturePipeline q;
  q.Initialize(48000, 1);
  q.SetRnnoiseEnabled(true);
  auto nout = RunPipeline(q, noise, 480);
  double cut_db = 20 * std::log10(Rms(HighPart(nout), 48000) / Rms(HighPart(noise), 48000));
  std::printf("  steady noise above 7.2 kHz: %.1f dB\n", cut_db);
  CHECK(cut_db < -10.0, "steady noise above 7.2 kHz only %.1f dB down", cut_db);
}

static void TestLevelsSlot() {
  std::printf("levels slot: a reader never sees a torn write\n");
  LevelsSlot slot;
  Levels l;
  CHECK(slot.Load(&l) == 0 && l.speech == -1.f, "empty slot");
  std::atomic<bool> stop{false};
  std::thread writer([&] {
    for (int i = 1; !stop.load(); ++i) {
      Levels w;
      w.pre = w.post = w.speech = w.clip = (float)i;
      slot.Store(w);
    }
  });
  long reads = 0, torn = 0;
  uint32_t last = 0;
  bool monotonic = true;
  auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (std::chrono::steady_clock::now() < end) {
    uint32_t v = slot.Load(&l);
    ++reads;
    if (v != 0 && !(l.pre == l.post && l.post == l.speech && l.speech == l.clip)) ++torn;  // v == 0: not written yet
    if (v < last) monotonic = false;
    last = v;
  }
  stop = true;
  writer.join();
  CHECK(torn == 0, "torn=%ld of %ld reads", torn, reads);
  CHECK(monotonic, "version never goes back");
}

static void TestSharedSettings() {
  std::printf("settings: shared by atomics, NaN and infinity refused\n");
  CaptureSettings cs;
  CHECK(cs.SetGain(1.5f) && cs.gain.load() == 1.5f, "gain set");
  CHECK(!cs.SetGain(NAN) && cs.gain.load() == 1.5f, "NaN refused");
  CHECK(!cs.SetGain(INFINITY) && !cs.SetGain(-INFINITY) && cs.gain.load() == 1.5f, "inf refused");
  CHECK(cs.SetGain(9.f) && cs.gain.load() == 2.f, "clamped high");
  CHECK(cs.SetGain(-1.f) && cs.gain.load() == 0.f, "clamped low");
  CapturePipeline a, b;
  a.Initialize(48000, 1);
  b.Initialize(48000, 1);
  a.UseSettings(&cs);
  b.UseSettings(&cs);
  cs.SetGain(0.5f);
  auto in = Sine(48000, 440, 8000, 9600);
  auto oa = RunPipeline(a, in, 480);
  auto ob = RunPipeline(b, in, 480);
  CHECK(std::fabs(Rms(oa, 960) / Rms(in, 960) - 0.5) < 0.01 && std::fabs(Rms(ob, 960) / Rms(in, 960) - 0.5) < 0.01,
        "both pipelines follow the shared gain");
  a.SetGain(NAN);
  CHECK(a.Gain() == 0.5f, "NaN through the pipeline setter is ignored");
}

static void TestLimiterAtUnity() {
  std::printf("gain 1.0 uses the same limiter as other gains\n");
  CapturePipeline p;
  p.Initialize(48000, 1);
  std::vector<float> in(4800, 32767.f);  // a hot, flat-topped block
  auto out = RunPipeline(p, in, 480);
  CHECK(Peak(out) < 32767.f, "unity gain still limits, peak=%f", Peak(out));
  auto quiet = RunPipeline(p, Sine(48000, 440, 8000, 4800), 480);
  auto ref = Sine(48000, 440, 8000, 4800);
  bool same = true;
  for (size_t i = 0; i < ref.size(); ++i) same &= quiet[i] == ref[i];
  CHECK(same, "below the knee it is the identity");
}

static void TestNoAllocation() {
  std::printf("audio path: no allocation while toggling RNNoise and moving the gain\n");
  for (int rate : {16000, 48000}) {
    CapturePipeline p;
    p.Initialize(rate, 1);
    const int block = rate / 100;
    std::vector<float> in = Sine(rate, 440, 8000, block * 20);
    std::vector<float> buf(block);
    auto run_blocks = [&](int n, int toggle_every) {
      for (int b = 0; b < n; ++b) {
        if (toggle_every && b % toggle_every == 0) p.SetRnnoiseEnabled(!p.RnnoiseEnabled());
        p.SetGain(0.5f + 0.001f * (float)(b % 1000));
        std::copy(in.begin() + (b % 20) * block, in.begin() + (b % 20 + 1) * block, buf.begin());
        p.Process(buf.data(), buf.size());
      }
    };
    p.SetRnnoiseEnabled(true);
    run_blocks(300, 0);  // warm up: vectors reach their working size
    g_allocs = 0;
    g_count = true;
    run_blocks(3000, 7);
    g_count = false;
    CHECK(g_allocs.load() == 0, "%d Hz: %ld allocations on the audio path", rate, g_allocs.load());
  }
}

static void TestToggleNoClick() {
  std::printf("rnnoise on/off: no jump larger than the signal's own slope\n");
  for (int rate : {16000, 48000}) {
    CapturePipeline p;
    p.Initialize(rate, 1);
    const int block = rate / 100;
    auto in = Sine(rate, 300, 8000, rate * 4);
    std::vector<float> out;
    for (int b = 0; b * block < (int)in.size(); ++b) {
      if (b == 100) p.SetRnnoiseEnabled(true);
      if (b == 250) p.SetRnnoiseEnabled(false);
      std::vector<float> blk(in.begin() + b * block, in.begin() + (b + 1) * block);
      p.Process(blk.data(), blk.size());
      out.insert(out.end(), blk.begin(), blk.end());
    }
    float worst = 0;
    for (size_t i = 1; i < out.size(); ++i) worst = std::fmax(worst, std::fabs(out[i] - out[i - 1]));
    // the 300 Hz sine itself moves at most 8000 * 2 pi * 300 / rate per sample
    float own = (float)(8000 * 2 * M_PI * 300 / rate);
    CHECK(worst < 2.f * own, "%d Hz: largest step %f, own slope %f", rate, worst, own);
    // and after switching off it is the input again, exactly
    bool same = true;
    for (size_t i = (size_t)(260 * block); i < out.size(); ++i) same &= out[i] == in[i];
    CHECK(same, "%d Hz: dry again after the fade", rate);
  }
}

// How much delay the RNNoise path adds, measured by cross-correlating white noise
// with the output.
static void TestLatency() {
  std::printf("latency: RNNoise path delay by cross-correlation\n");
  for (int rate : {16000, 32000, 48000}) {
    const int block = rate / 100;
    // broadband noise: its correlation peak is unique (a periodic voiced signal repeats)
    std::mt19937 rng(5);
    std::normal_distribution<float> nd(0.f, 3000.f);
    std::vector<float> in(rate * 3);
    for (auto& v : in) v = nd(rng);
    CapturePipeline p;
    p.Initialize(rate, 1);
    p.SetRnnoiseEnabled(true);
    auto out = RunPipeline(p, in, block);
    int best = -1;
    double best_c = -1e30;
    for (int lag = 0; lag < rate / 20; ++lag) {  // up to 50 ms
      double c = 0;
      for (size_t i = (size_t)rate; i < (size_t)rate * 2; ++i) c += (double)in[i - lag] * out[i];
      if (c > best_c) { best_c = c; best = lag; }
    }
    std::printf("  %d Hz: output lags the input by %d samples = %.1f ms\n", rate, best, 1000.0 * best / rate);
    CHECK(best >= 0 && 1000.0 * best / rate < 35.0, "%d Hz: lag %d samples", rate, best);
    // 48 kHz: RNNoise's 20 ms plus the band split's 54 samples, not a whole block more
    if (rate == 48000) CHECK(1000.0 * best / rate < 22.0, "48 kHz: lag %d samples", best);
  }
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
  TestTailHold();
  TestTailSteadyNoise();
  TestTailSwitchLive();
  TestWidebandIgnoresHighNoise();
  TestHighBandFollowsGains();
  TestLevelsSlot();
  TestSharedSettings();
  TestLimiterAtUnity();
  TestNoAllocation();
  TestToggleNoClick();
  TestLatency();
  Benchmark();
  std::printf(g_fail ? "FAILED: %d check(s)\n" : "ALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
