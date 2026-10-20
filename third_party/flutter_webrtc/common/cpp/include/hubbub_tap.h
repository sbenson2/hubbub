// Hubbub patch: diagnostic audio taps. Measurement only, off by default.
//
//  WavTap     records mono 16-bit audio to a 48 kHz WAV file. The audio thread only
//             copies samples into a lock-free ring buffer; a writer thread resamples
//             to 48 kHz and does all file I/O. When the tap is off, Push* is one
//             relaxed atomic load.
//  WavInject  replaces the capture signal with a WAV file (test only).
//
// Pure C++ (no libwebrtc), so it can be unit tested. See HUBBUB_PATCHES.md.
#ifndef HUBBUB_TAP_H_
#define HUBBUB_TAP_H_

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include "hubbub_audio.h"

namespace hubbub {

inline int64_t EpochMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

// fopen for a UTF-8 path (Windows paths with non-ASCII user names), without the CRT warning.
inline std::FILE* OpenFileUtf8(const std::string& path, const char* mode) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
  if (n <= 0) return nullptr;
  std::wstring w((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &w[0], n);
  std::wstring m;
  for (const char* p = mode; *p; ++p) m.push_back((wchar_t)*p);
  std::FILE* f = nullptr;
  return _wfopen_s(&f, w.c_str(), m.c_str()) == 0 ? f : nullptr;
#else
  return std::fopen(path.c_str(), mode);
#endif
}

struct TapStats {
  std::string path;
  int64_t start_ms = 0;        // wall clock (ms since the epoch) when Start was called
  int64_t first_sample_ms = 0; // wall clock of the first Push (0 = none)
  int64_t last_sample_ms = 0;  // wall clock of the last Push
  int64_t samples = 0;         // 48 kHz samples written
  int64_t dropped_chunks = 0;  // ring buffer full
  bool capped = false;
  int64_t max_gap_ms = 0;      // longest wait between two Push calls
  int64_t gaps_over_50ms = 0;  // pushes that came more than 50 ms after the previous one
  int source_rate = 0;         // rate of the audio as it arrived
};

class WavTap {
 public:
  static constexpr int kOutRate = 48000;
  static constexpr size_t kRingBytes = 1u << 22;  // 4 MiB

  ~WavTap() { Stop(nullptr); }

  bool active() const { return active_.load(std::memory_order_relaxed); }

  // Platform thread. False (and |err|) when the file cannot be created.
  bool Start(const std::string& path, std::string* err, double max_seconds = 600.0) {
    if (active_.load() || thread_.joinable()) {
      if (err) *err = "already recording";
      return false;
    }
    file_ = OpenFileUtf8(path, "wb");
    if (!file_) {
      if (err) *err = "cannot create " + path;
      return false;
    }
    WriteHeader(0);
    ring_.assign(kRingBytes, 0);
    head_.store(0);
    tail_.store(0);
    stats_ = TapStats();
    stats_.path = path;
    stats_.start_ms = EpochMs();
    first_ms_.store(0);
    last_ms_.store(0);
    max_gap_.store(0);
    gaps_.store(0);
    dropped_.store(0);
    capped_.store(false);
    src_rate_.store(0);
    max_samples_ = (int64_t)(max_seconds * kOutRate);
    stop_.store(false);
    thread_ = std::thread([this] { WriterLoop(); });
    active_.store(true);
    return true;
  }

  // Platform thread. Waits for a Push in flight, drains the ring, fixes the
  // header and closes the file.
  bool Stop(TapStats* out) {
    if (!thread_.joinable()) return false;
    active_.store(false);
    for (int i = 0; i < 2000 && users_.load() > 0; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    stop_.store(true);
    thread_.join();
    stats_.first_sample_ms = first_ms_.load();
    stats_.last_sample_ms = last_ms_.load();
    stats_.max_gap_ms = max_gap_.load();
    stats_.gaps_over_50ms = gaps_.load();
    stats_.dropped_chunks = dropped_.load();
    stats_.capped = capped_.load();
    stats_.source_rate = src_rate_.load();
    if (out) *out = stats_;
    std::vector<uint8_t>().swap(ring_);
    return true;
  }

  // Audio thread: floats in the 16-bit range (WebRTC's APM format), mono.
  void PushFloat(const float* x, size_t n, int rate) {
    if (!active_.load(std::memory_order_relaxed)) return;
    Guard g(users_);
    if (!active_.load() || capped_.load(std::memory_order_relaxed) || n == 0) return;
    Header h{(uint32_t)rate, 1u, (uint32_t)n};
    if (!Reserve(sizeof h + n * 2)) return;
    uint64_t pos = head_.load(std::memory_order_relaxed);
    Copy(pos, &h, sizeof h);
    pos += sizeof h;
    int16_t tmp[512];
    size_t done = 0;
    while (done < n) {
      size_t m = n - done < 512 ? n - done : 512;
      for (size_t i = 0; i < m; ++i) {
        float v = x[done + i];
        v = v > 32767.f ? 32767.f : v < -32768.f ? -32768.f : v;
        tmp[i] = (int16_t)std::lrintf(v);
      }
      Copy(pos, tmp, m * 2);
      pos += m * 2;
      done += m;
    }
    Publish(pos, rate);
  }

  // Audio thread: interleaved 16-bit PCM.
  void PushPcm16(const int16_t* x, size_t frames, int rate, size_t channels) {
    if (!active_.load(std::memory_order_relaxed)) return;
    Guard g(users_);
    if (!active_.load() || capped_.load(std::memory_order_relaxed) || frames == 0 || channels == 0 ||
        channels > 8)
      return;
    Header h{(uint32_t)rate, (uint32_t)channels, (uint32_t)frames};
    size_t bytes = frames * channels * 2;
    if (!Reserve(sizeof h + bytes)) return;
    uint64_t pos = head_.load(std::memory_order_relaxed);
    Copy(pos, &h, sizeof h);
    Copy(pos + sizeof h, x, bytes);
    Publish(pos + sizeof h + bytes, rate);
  }

 private:
  struct Header { uint32_t rate, channels, frames; };
  struct Guard {
    explicit Guard(std::atomic<int>& u) : u_(u) { u_.fetch_add(1); }
    ~Guard() { u_.fetch_sub(1); }
    std::atomic<int>& u_;
  };

  bool Reserve(size_t bytes) {
    uint64_t used = head_.load(std::memory_order_relaxed) - tail_.load(std::memory_order_acquire);
    if (used + bytes > ring_.size()) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    return true;
  }
  void Copy(uint64_t pos, const void* src, size_t n) {
    size_t cap = ring_.size(), off = (size_t)(pos % cap);
    size_t first = n < cap - off ? n : cap - off;
    std::memcpy(ring_.data() + off, src, first);
    if (first < n) std::memcpy(ring_.data(), (const uint8_t*)src + first, n - first);
  }
  void Peek(uint64_t pos, void* dst, size_t n) const {
    size_t cap = ring_.size(), off = (size_t)(pos % cap);
    size_t first = n < cap - off ? n : cap - off;
    std::memcpy(dst, ring_.data() + off, first);
    if (first < n) std::memcpy((uint8_t*)dst + first, ring_.data(), n - first);
  }
  void Publish(uint64_t newhead, int rate) {
    int64_t now = EpochMs();
    if (first_ms_.load(std::memory_order_relaxed) == 0) first_ms_.store(now);
    int64_t prev = last_ms_.load(std::memory_order_relaxed);
    if (prev != 0) {
      int64_t gap = now - prev;
      if (gap > 50) gaps_.fetch_add(1, std::memory_order_relaxed);
      if (gap > max_gap_.load(std::memory_order_relaxed)) max_gap_.store(gap, std::memory_order_relaxed);
    }
    last_ms_.store(now, std::memory_order_relaxed);
    src_rate_.store(rate, std::memory_order_relaxed);
    head_.store(newhead, std::memory_order_release);
  }

  void WriteHeader(uint32_t data_bytes) {
    uint8_t h[44];
    auto u32 = [&](int o, uint32_t v) { for (int i = 0; i < 4; ++i) h[o + i] = (v >> (8 * i)) & 255; };
    auto u16 = [&](int o, uint16_t v) { h[o] = v & 255; h[o + 1] = v >> 8; };
    std::memcpy(h, "RIFF", 4); u32(4, 36 + data_bytes);
    std::memcpy(h + 8, "WAVEfmt ", 8); u32(16, 16); u16(20, 1); u16(22, 1);
    u32(24, kOutRate); u32(28, kOutRate * 2); u16(32, 2); u16(34, 16);
    std::memcpy(h + 36, "data", 4); u32(40, data_bytes);
    std::fseek(file_, 0, SEEK_SET);
    std::fwrite(h, 1, 44, file_);
    std::fseek(file_, 0, SEEK_END);
  }

  void WriterLoop() {
    std::vector<float> mono, res;
    std::vector<int16_t> pcm, out;
    std::vector<int16_t> chunk;
    std::unique_ptr<RationalResampler> rs;
    int rs_rate = 0;
    int64_t written = 0;
    auto last_flush = std::chrono::steady_clock::now();
    for (;;) {
      bool did = false;
      for (;;) {
        uint64_t tail = tail_.load(std::memory_order_relaxed);
        uint64_t head = head_.load(std::memory_order_acquire);
        if (head - tail < sizeof(Header)) break;
        Header h;
        Peek(tail, &h, sizeof h);
        size_t bytes = (size_t)h.frames * h.channels * 2;
        chunk.resize((bytes + 1) / 2);
        Peek(tail + sizeof h, chunk.data(), bytes);
        tail_.store(tail + sizeof h + bytes, std::memory_order_release);
        did = true;
        if (h.rate == 0 || written >= max_samples_) { if (written >= max_samples_) capped_.store(true); continue; }
        mono.resize(h.frames);
        for (uint32_t i = 0; i < h.frames; ++i) {
          float s = 0;
          for (uint32_t c = 0; c < h.channels; ++c) s += chunk[(size_t)i * h.channels + c];
          mono[i] = s / (float)h.channels;
        }
        const std::vector<float>* src = &mono;
        if ((int)h.rate != kOutRate) {
          if (!rs || rs_rate != (int)h.rate) {
            rs.reset(new RationalResampler((int)h.rate, kOutRate));
            rs_rate = (int)h.rate;
          }
          res.clear();
          rs->Process(mono.data(), mono.size(), res);
          src = &res;
        }
        out.resize(src->size());
        for (size_t i = 0; i < src->size(); ++i) {
          float v = (*src)[i];
          v = v > 32767.f ? 32767.f : v < -32768.f ? -32768.f : v;
          out[i] = (int16_t)std::lrintf(v);
        }
        int64_t room = max_samples_ - written;
        size_t n = (int64_t)out.size() > room ? (size_t)room : out.size();
        std::fwrite(out.data(), 2, n, file_);
        written += (int64_t)n;
        if ((int64_t)n < (int64_t)out.size()) capped_.store(true);
      }
      auto now = std::chrono::steady_clock::now();
      if (now - last_flush > std::chrono::seconds(1)) {  // a crash leaves a usable file
        WriteHeader((uint32_t)(written * 2));
        std::fflush(file_);
        last_flush = now;
      }
      if (stop_.load() && !did) break;
      if (!did) std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    WriteHeader((uint32_t)(written * 2));
    std::fclose(file_);
    file_ = nullptr;
    stats_.samples = written;
  }

  std::atomic<bool> active_{false}, stop_{false}, capped_{false};
  std::atomic<int> users_{0};
  std::atomic<uint64_t> head_{0}, tail_{0};
  std::atomic<int64_t> first_ms_{0}, last_ms_{0}, dropped_{0}, max_gap_{0}, gaps_{0};
  std::atomic<int> src_rate_{0};
  std::vector<uint8_t> ring_;
  std::FILE* file_ = nullptr;
  std::thread thread_;
  TapStats stats_;
  int64_t max_samples_ = 0;
};

// Reads a PCM16/float32 WAV into mono floats in the 16-bit range at 48 kHz.
inline bool ReadWavMono48k(const std::string& path, std::vector<float>* out, std::string* err) {
  std::FILE* f = OpenFileUtf8(path, "rb");
  if (!f) { if (err) *err = "cannot open " + path; return false; }
  std::vector<uint8_t> d;
  uint8_t buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
  std::fclose(f);
  auto rd32 = [&](size_t o) { return (uint32_t)d[o] | d[o + 1] << 8 | d[o + 2] << 16 | (uint32_t)d[o + 3] << 24; };
  auto rd16 = [&](size_t o) { return (uint32_t)(d[o] | d[o + 1] << 8); };
  if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) || std::memcmp(d.data() + 8, "WAVE", 4)) {
    if (err) *err = "not a WAV file";
    return false;
  }
  uint32_t fmt = 0, ch = 0, rate = 0, bits = 0;
  size_t data_off = 0, data_len = 0;
  for (size_t p = 12; p + 8 <= d.size();) {
    uint32_t len = rd32(p + 4);
    if (!std::memcmp(d.data() + p, "fmt ", 4) && p + 8 + 16 <= d.size()) {
      fmt = rd16(p + 8); ch = rd16(p + 10); rate = rd32(p + 12); bits = rd16(p + 22);
      if (fmt == 0xFFFE && len >= 26 && p + 8 + 26 <= d.size()) fmt = rd16(p + 8 + 24);
    } else if (!std::memcmp(d.data() + p, "data", 4)) {
      data_off = p + 8;
      data_len = len;
      if (data_off + data_len > d.size()) data_len = d.size() - data_off;
      break;
    }
    p += 8 + (size_t)len + (len & 1);
  }
  if (!ch || !rate || !data_off || !((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32))) {
    if (err) *err = "need 16-bit PCM or 32-bit float WAV";
    return false;
  }
  size_t bytes_per = bits / 8, frames = data_len / (bytes_per * ch);
  std::vector<float> mono(frames);
  for (size_t i = 0; i < frames; ++i) {
    float s = 0;
    for (uint32_t c = 0; c < ch; ++c) {
      size_t o = data_off + (i * ch + c) * bytes_per;
      if (fmt == 1) s += (float)(int16_t)rd16(o);
      else { uint32_t u = rd32(o); float v; std::memcpy(&v, &u, 4); s += v * 32768.f; }
    }
    mono[i] = s / (float)ch;
  }
  if ((int)rate == 48000) { *out = std::move(mono); return true; }
  RationalResampler rs((int)rate, 48000);
  out->clear();
  rs.Process(mono.data(), mono.size(), *out);
  std::vector<float> flush((size_t)rate / 20, 0.f);  // push out the filter tail
  rs.Process(flush.data(), flush.size(), *out);
  return true;
}

// Replaces the capture signal (mono, copied to every channel). Armed: silence.
// Playing: the file from its first sample, then silence.
class WavInject {
 public:
  bool active() const { return state_.load(std::memory_order_relaxed) != 0; }

  // Platform thread.
  bool Load(const std::string& path, std::string* err) {
    std::vector<float> x48;
    if (!ReadWavMono48k(path, &x48, err)) return false;
    Unload();
    for (int r : {16000, 32000, 48000}) {
      auto& v = data_[r == 16000 ? 0 : r == 32000 ? 1 : 2];
      if (r == 48000) v = x48;
      else {
        RationalResampler rs(48000, r);
        v.clear();
        rs.Process(x48.data(), x48.size(), v);
      }
    }
    pos_.store(0);
    state_.store(1);
    return true;
  }
  int64_t Play() {
    pos_.store(0);
    finished_.store(false);
    state_.store(2);
    return EpochMs();
  }
  void Unload() {
    state_.store(0);
    for (int i = 0; i < 2000 && users_.load() > 0; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    for (auto& v : data_) std::vector<float>().swap(v);
  }
  bool finished() const {
    return state_.load() == 2 && finished_.load();
  }

  // Audio thread: planar |channels| blocks of |n|, floats in the 16-bit range.
  void Fill(float* buf, size_t n, size_t channels, int rate) {
    if (state_.load(std::memory_order_relaxed) == 0) return;
    users_.fetch_add(1);
    int st = state_.load();
    if (st != 0) {
      int idx = rate == 16000 ? 0 : rate == 32000 ? 1 : rate == 48000 ? 2 : -1;
      const std::vector<float>* v = idx >= 0 ? &data_[idx] : nullptr;
      int64_t pos = pos_.load(std::memory_order_relaxed);
      for (size_t i = 0; i < n; ++i) {
        float s = 0;
        if (st == 2 && v && pos + (int64_t)i < (int64_t)v->size()) s = (*v)[(size_t)pos + i];
        for (size_t c = 0; c < channels; ++c) buf[c * n + i] = s;
      }
      if (st == 2) {
        pos += (int64_t)n;
        pos_.store(pos);
        if (!v || pos >= (int64_t)v->size()) finished_.store(true);
      }
    }
    users_.fetch_sub(1);
  }

 private:
  std::atomic<int> state_{0};  // 0 off, 1 armed (silence), 2 playing
  std::atomic<int> users_{0};
  std::atomic<int64_t> pos_{0};
  std::atomic<bool> finished_{false};
  std::vector<float> data_[3];  // at 16, 32, 48 kHz
};

}  // namespace hubbub

#endif  // HUBBUB_TAP_H_
