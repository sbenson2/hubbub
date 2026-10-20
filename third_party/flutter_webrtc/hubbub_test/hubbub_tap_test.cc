// Tests for the diagnostic taps (hubbub_tap.h): WAV output, ring buffer wrap and
// resampling, the cap, injection.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "hubbub_tap.h"

static int g_fail = 0;
#define CHECK(c)                                                       \
  do {                                                                 \
    if (!(c)) {                                                        \
      std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);         \
      ++g_fail;                                                        \
    }                                                                  \
  } while (0)

static std::string TmpPath(const char* name) {
  const char* t = std::getenv("TEMP");
  if (!t) t = std::getenv("TMPDIR");
  if (!t) t = "/tmp";
  return std::string(t) + "/" + name;
}

static std::vector<int16_t> ReadWav(const std::string& path, int* rate = nullptr) {
  std::vector<int16_t> out;
  std::FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return out;
  uint8_t h[44];
  if (std::fread(h, 1, 44, f) != 44) { std::fclose(f); return out; }
  uint32_t data = h[40] | h[41] << 8 | h[42] << 16 | (uint32_t)h[43] << 24;
  if (rate) *rate = h[24] | h[25] << 8 | h[26] << 16;
  out.resize(data / 2);
  size_t n = std::fread(out.data(), 2, out.size(), f);
  out.resize(n);
  std::fclose(f);
  return out;
}

static void TestRecordSine16k() {
  std::string p = TmpPath("hubbub_tap_sine.wav");
  hubbub::WavTap tap;
  std::string err;
  CHECK(!tap.active());
  CHECK(tap.Start(p, &err));
  CHECK(tap.active());
  const int n_blocks = 1500;  // 15 s at 16 kHz: wraps the 4 MiB ring a few times if the writer lagged
  std::vector<float> blk(160);
  long t = 0;
  for (int b = 0; b < n_blocks; ++b) {
    for (int i = 0; i < 160; ++i, ++t) blk[i] = 8000.f * std::sin(2 * 3.14159265358979 * 1000.0 * t / 16000.0);
    tap.PushFloat(blk.data(), 160, 16000);
    if (b % 50 == 0) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  hubbub::TapStats st;
  CHECK(tap.Stop(&st));
  CHECK(!tap.active());
  int rate = 0;
  auto x = ReadWav(p, &rate);
  CHECK(rate == 48000);
  CHECK(st.dropped_chunks == 0);
  // 15 s at 48 kHz, within the resampler's few samples of delay
  CHECK(std::abs((long)x.size() - 15L * 48000) < 200);
  CHECK((long)st.samples == (long)x.size());
  // 1 kHz tone, amplitude about 8000, after the start-up
  double peak = 0;
  for (size_t i = 5000; i < 20000 && i < x.size(); ++i) peak = std::fmax(peak, std::fabs((double)x[i]));
  CHECK(peak > 7600 && peak < 8400);
  CHECK(st.source_rate == 16000);
  CHECK(st.first_sample_ms >= st.start_ms);
  std::remove(p.c_str());
}

static void TestPcm16StereoAndCap() {
  std::string p = TmpPath("hubbub_tap_cap.wav");
  hubbub::WavTap tap;
  std::string err;
  CHECK(tap.Start(p, &err, 1.0));  // cap: 1 second
  std::vector<int16_t> blk(480 * 2);
  for (int b = 0; b < 400; ++b) {
    for (int i = 0; i < 480; ++i) { blk[2 * i] = 1000; blk[2 * i + 1] = 3000; }
    tap.PushPcm16(blk.data(), 480, 48000, 2);
    if (b % 20 == 0) std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  hubbub::TapStats st;
  tap.Stop(&st);
  auto x = ReadWav(p);
  CHECK(x.size() == 48000);
  CHECK(st.capped);
  CHECK(x.size() > 100 && x[100] == 2000);  // the channels are averaged
  std::remove(p.c_str());
}

static void TestBadPathAndIdempotentStop() {
  hubbub::WavTap tap;
  std::string err;
  CHECK(!tap.Start("/nonexistent-dir/x/y.wav", &err));
  CHECK(!err.empty());
  CHECK(!tap.Stop(nullptr));
  float z[160] = {0};
  tap.PushFloat(z, 160, 16000);  // off: does nothing
}

static void TestInject() {
  std::string p = TmpPath("hubbub_inject_src.wav");
  {  // a 48 kHz file of 0.5 s with value 4000
    hubbub::WavTap w;
    std::string err;
    CHECK(w.Start(p, &err));
    std::vector<float> blk(480, 4000.f);
    for (int i = 0; i < 50; ++i) w.PushFloat(blk.data(), 480, 48000);
    w.Stop(nullptr);
  }
  hubbub::WavInject inj;
  std::string err;
  CHECK(!inj.active());
  CHECK(inj.Load(p, &err));
  CHECK(inj.active());
  std::vector<float> buf(160 * 2, 123.f);
  inj.Fill(buf.data(), 160, 2, 16000);
  CHECK(buf[0] == 0.f && buf[160] == 0.f);  // armed: silence, both channels
  inj.Play();
  long loud = 0;
  for (int b = 0; b < 100; ++b) {  // 1 s of 10 ms blocks
    inj.Fill(buf.data(), 160, 2, 16000);
    for (int i = 0; i < 160; ++i) if (std::fabs(buf[i] - 4000.f) < 200.f && buf[160 + i] == buf[i]) ++loud;
  }
  CHECK(loud > 7500 && loud < 8100);  // about 0.5 s at 16 kHz
  CHECK(inj.finished());
  inj.Unload();
  CHECK(!inj.active());
  buf.assign(320, 7.f);
  inj.Fill(buf.data(), 160, 2, 16000);
  CHECK(buf[0] == 7.f);  // off: untouched
  CHECK(!inj.Load("/nonexistent.wav", &err));
  std::remove(p.c_str());
}

int main() {
  TestRecordSine16k();
  TestPcm16StereoAndCap();
  TestBadPathAndIdempotentStop();
  TestInject();
  if (g_fail) { std::printf("FAILED (%d)\n", g_fail); return 1; }
  std::printf("ALL PASSED\n");
  return 0;
}
