// Hubbub patch: capture-side audio pipeline (RNNoise, input gain, limiter, peak
// meter). Pure C++ with no libwebrtc dependency so it can be unit tested; the
// libwebrtc adapter lives in hubbub_capture_processor.h.
#ifndef HUBBUB_AUDIO_H_
#define HUBBUB_AUDIO_H_

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

struct DenoiseState;

namespace hubbub {

// WebRTC's audio processing uses floats in the 16-bit range (+-32768).
constexpr float kFullScale = 32768.f;

// Soft limiter in 16-bit float units. Identity up to the knee, then a smooth
// tanh curve that approaches (never reaches) full scale. |result| < 32768.
float SoftLimit(float x);

// Collects samples of any chunk size and hands out fixed-size frames.
class FrameRechunker {
 public:
  explicit FrameRechunker(size_t frame) : frame_(frame) {}
  template <typename F>
  void Push(const float* in, size_t n, F&& on_frame) {
    buf_.insert(buf_.end(), in, in + n);
    size_t used = 0;
    while (buf_.size() - used >= frame_) {
      on_frame(buf_.data() + used);
      used += frame_;
    }
    buf_.erase(buf_.begin(), buf_.begin() + used);
  }
  size_t Pending() const { return buf_.size(); }
  void Clear() { buf_.clear(); }
  void Reserve(size_t n) { buf_.reserve(n); }

 private:
  size_t frame_;
  std::vector<float> buf_;
};

// Streaming windowed-sinc resampler between two integer rates (unity gain).
class RationalResampler {
 public:
  RationalResampler(int in_rate, int out_rate);
  // Appends the output samples that can be produced so far to |out|.
  void Process(const float* in, size_t n, std::vector<float>& out);
  void Reset();

 private:
  int a_, b_;       // in_rate/g, out_rate/g
  int half_;        // kernel half width in input samples
  std::vector<std::vector<float>> phases_;  // b_ phases, 2*half_ taps each
  std::vector<float> buf_;  // input history, buf_[0] is absolute index start_
  int64_t start_ = 0;
  int64_t total_ = 0;   // input samples received (plus the zero priming)
  int64_t k_ = 0;       // next output index
  void Prime();
};

struct Levels {
  float pre = 0;      // peak before RNNoise and gain, 0..1
  float post = 0;     // peak after gain and limiter, 0..1
  float speech = -1;  // RNNoise speech probability 0..1, -1 when RNNoise is off
  float clip = 0;     // fraction of blocks in the window with pre peak >= 0.98
};

// What the user chose: shared by the pipelines and written by any thread, read
// by the audio thread once at the start of every block. Plain atomics, so the
// setters never touch pipeline internals.
struct CaptureSettings {
  std::atomic<bool> rnnoise{false};
  std::atomic<float> gain{1.f};  // factor 0..2
  // NaN and infinity are refused (false); other values are clamped to 0..2.
  bool SetGain(float g) {
    if (!std::isfinite(g)) return false;
    gain.store(g < 0.f ? 0.f : g > 2.f ? 2.f : g, std::memory_order_relaxed);
    return true;
  }
};

// Latest levels, written by the audio thread (a seqlock with atomic fields, no
// lock, no allocation) and polled by another thread. One writer.
class LevelsSlot {
 public:
  LevelsSlot() { v_[2].store(-1.f); }
  // Sequentially consistent operations throughout: a few stores 20 times a
  // second cost nothing, and it avoids reasoning about fences.
  void Store(const Levels& l) {
    uint32_t s = seq_.load();
    seq_.store(s + 1);  // odd: write in progress
    v_[0].store(l.pre);
    v_[1].store(l.post);
    v_[2].store(l.speech);
    v_[3].store(l.clip);
    seq_.store(s + 2);
  }
  // Copies the latest levels and returns which write they came from (0 = none yet).
  uint32_t Load(Levels* l) const {
    for (;;) {
      uint32_t s1 = seq_.load();
      if (s1 & 1) continue;
      l->pre = v_[0].load();
      l->post = v_[1].load();
      l->speech = v_[2].load();
      l->clip = v_[3].load();
      if (seq_.load() == s1) return s1;
    }
  }

 private:
  std::atomic<uint32_t> seq_{0};
  std::atomic<float> v_[4]{};  // pre, post, speech, clip
};

// In-place mono processor: RNNoise (any rate, resampled to 48 kHz), then input
// gain with a soft limiter, then peak metering. Settings may be changed from
// any thread (they are atomics); Initialize and Process run on the audio thread.
class CapturePipeline {
 public:
  using LevelsCallback = std::function<void(const Levels&)>;
  CapturePipeline();
  ~CapturePipeline();
  void Initialize(int sample_rate, int channels);
  void Process(float* samples, size_t n);
  // Own settings, for standalone use and tests. A processor with several
  // pipelines points them all at one shared CaptureSettings instead.
  void SetRnnoiseEnabled(bool on) { own_.rnnoise.store(on); }
  void SetGain(float g) { own_.SetGain(g); }
  float Gain() const { return s_->gain.load(); }
  bool RnnoiseEnabled() const { return s_->rnnoise.load(); }
  void UseSettings(const CaptureSettings* s) { s_ = s ? s : &own_; }
  // Called about 20 times a second from the audio thread (tests only; the
  // adapter uses UseLevelsSlot so nothing allocates on the audio thread).
  void SetLevelsCallback(LevelsCallback cb) { cb_ = std::move(cb); }
  void UseLevelsSlot(LevelsSlot* slot) { slot_ = slot; }

 private:
  void ResetDenoise();
  // Returns how many samples at the front were zero filled (RNNoise not primed).
  size_t RunDenoise(float* samples, size_t n);

  CaptureSettings own_;
  const CaptureSettings* s_ = &own_;
  LevelsCallback cb_;
  LevelsSlot* slot_ = nullptr;
  int rate_ = 48000;
  float applied_gain_ = 1.f;

  // RNNoise state. Everything is allocated in Initialize, so turning RNNoise
  // on or off on the audio thread allocates nothing.
  DenoiseState* st_ = nullptr;
  bool denoise_active_ = false;
  float mix_ = 0.f;  // 0 = dry, 1 = RNNoise output; moves over one block
  std::unique_ptr<RationalResampler> up_, down_;
  FrameRechunker chunker_{480};
  std::vector<float> scratch_, out48_, wet_;
  std::vector<float> fifo_;  // processed samples at the native rate
  float speech_sum_ = 0;
  int speech_n_ = 0;

  // Meter window
  size_t window_len_ = 2400;
  size_t window_pos_ = 0;
  float pre_peak_ = 0, post_peak_ = 0;
  int blocks_ = 0, clipped_blocks_ = 0;
};

}  // namespace hubbub

#endif  // HUBBUB_AUDIO_H_
