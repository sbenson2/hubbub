// Offline run of the capture hook over a WAV file, for tuning without the app.
// It drives the real CaptureProcessor (RNNoise, gain, limiter) with the block
// layout libwebrtc uses for a rate, injects the file the way the app's inject
// tap does (WavInject: 48 kHz file, resampled to the hook rate), and writes what
// leaves the hook the way the "processed" tap does (16-bit, resampled to 48 kHz).
// Score the output with tools/audio_compare.py against the clean reference.
//
//   hubbub_offline IN.wav OUT.wav [--rate 16000|48000] [--rnnoise 0|1]
//                  [--classic 0|1] [--gain G] [--tail S] [--speech OUT.csv]
//
// --rate 48000 uses Process(bands=3, frames=480), anything else bands=1 and
// rate/100 frames (the layouts in hubbub_capture_processor.h). --tail adds S
// seconds of silence after the file (default 2.5, like the integration test).
// --speech writes the RNNoise speech probability of every 50 ms meter window.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "hubbub_capture_processor.h"

static bool WriteWav16(const std::string& path, const std::vector<float>& x, int rate) {
  std::FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
  uint32_t bytes = (uint32_t)(x.size() * 2);
  std::fwrite("RIFF", 1, 4, f);
  w32(36 + bytes);
  std::fwrite("WAVEfmt ", 1, 8, f);
  w32(16);
  w16(1);
  w16(1);
  w32((uint32_t)rate);
  w32((uint32_t)rate * 2);
  w16(2);
  w16(16);
  std::fwrite("data", 1, 4, f);
  w32(bytes);
  for (float v : x) {
    v = v > 32767.f ? 32767.f : v < -32768.f ? -32768.f : v;
    int16_t s = (int16_t)std::lrintf(v);
    std::fwrite(&s, 2, 1, f);
  }
  std::fclose(f);
  return true;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s IN.wav OUT.wav [--rate R] [--rnnoise 0|1] [--classic 0|1] "
                 "[--gain G] [--tail S] [--speech OUT.csv]\n", argv[0]);
    return 2;
  }
  std::string in_path = argv[1], out_path = argv[2], speech_path;
  int rate = 48000;
  bool rnnoise = true, classic = false;
  float gain = 1.f, tail_s = 2.5f;
  for (int i = 3; i + 1 < argc; i += 2) {
    std::string k = argv[i];
    const char* v = argv[i + 1];
    if (k == "--rate") rate = std::atoi(v);
    else if (k == "--rnnoise") rnnoise = std::atoi(v) != 0;
    else if (k == "--classic") classic = std::atoi(v) != 0;
    else if (k == "--gain") gain = (float)std::atof(v);
    else if (k == "--tail") tail_s = (float)std::atof(v);
    else if (k == "--speech") speech_path = v;
    else {
      std::fprintf(stderr, "unknown option %s\n", k.c_str());
      return 2;
    }
  }
  const int frames = rate / 100;
  const int bands = rate == 48000 ? 3 : 1;
  hubbub::LogEnabled().store(false);

  hubbub::CaptureProcessor p;
  p.SetRnnoiseEnabled(rnnoise);
  p.SetGain(gain);
  p.SetTailMode(classic, -20.f, 200.f);
  p.Initialize(rate, 1);
  std::string err;
  if (!p.inject().Load(in_path, &err)) {
    std::fprintf(stderr, "cannot read %s: %s\n", in_path.c_str(), err.c_str());
    return 1;
  }
  p.inject().Play();

  std::vector<float> block((size_t)frames), out;
  std::FILE* speech = speech_path.empty() ? nullptr : std::fopen(speech_path.c_str(), "w");
  if (speech) std::fprintf(speech, "t_s,speech\n");
  uint32_t seen = 0;
  long blocks = 0, after = 0;
  const long after_blocks = std::lround(tail_s * 100.f);
  while (after < after_blocks) {
    std::fill(block.begin(), block.end(), 0.f);
    p.Process(bands, frames, frames, block.data());
    // the processed tap stores 16-bit samples at the hook rate
    for (float v : block) {
      v = v > 32767.f ? 32767.f : v < -32768.f ? -32768.f : v;
      out.push_back((float)std::lrintf(v));
    }
    ++blocks;
    if (p.inject().finished()) ++after;
    hubbub::Levels l;
    uint32_t s = p.levels().Load(&l);
    if (speech && s != seen) std::fprintf(speech, "%.3f,%.4f\n", blocks / 100.0, l.speech);
    seen = s;
  }
  if (speech) std::fclose(speech);
  if (rate != 48000) {
    hubbub::RationalResampler rs(rate, 48000);
    std::vector<float> o48;
    rs.Process(out.data(), out.size(), o48);
    out.swap(o48);
  }
  if (!WriteWav16(out_path, out, 48000)) {
    std::fprintf(stderr, "cannot write %s\n", out_path.c_str());
    return 1;
  }
  std::printf("rate=%d bands=%d frames=%d blocks=%ld processed=%ld skipped=%ld -> %s\n", rate, bands,
              frames, blocks, p.processed(), p.skipped(), out_path.c_str());
  return p.skipped() == 0 ? 0 : 1;
}
