// Hubbub patch: capture-side audio pipeline (RNNoise, input gain, limiter, peak
// meter). Pure C++ with no libwebrtc dependency so it can be unit tested; the
// libwebrtc adapter lives in hubbub_capture_processor.h.
#ifndef HUBBUB_AUDIO_H_
#define HUBBUB_AUDIO_H_

#include <atomic>
#include <cstddef>
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

// In-place mono processor: RNNoise (any rate, resampled to 48 kHz), then input
// gain with a soft limiter, then peak metering. Settings may be changed from
// any thread; Process runs on the audio thread.
class CapturePipeline {
 public:
  using LevelsCallback = std::function<void(const Levels&)>;
  CapturePipeline();
  ~CapturePipeline();
  void Initialize(int sample_rate, int channels);
  void Process(float* samples, size_t n);
  void SetRnnoiseEnabled(bool on) { rnnoise_.store(on); }
  void SetGain(float g) { gain_.store(g < 0 ? 0 : g > 2 ? 2 : g); }
  float Gain() const { return gain_.load(); }
  bool RnnoiseEnabled() const { return rnnoise_.load(); }
  // Called about 20 times a second from the audio thread.
  void SetLevelsCallback(LevelsCallback cb) { cb_ = std::move(cb); }

 private:
  void ResetDenoise();
  void RunDenoise(float* samples, size_t n);

  std::atomic<bool> rnnoise_{false};
  std::atomic<float> gain_{1.f};
  LevelsCallback cb_;
  int rate_ = 48000;
  float applied_gain_ = 1.f;

  // RNNoise state
  DenoiseState* st_ = nullptr;
  bool denoise_active_ = false;
  std::unique_ptr<RationalResampler> up_, down_;
  FrameRechunker chunker_{480};
  std::vector<float> scratch_, out48_, native_out_;
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
