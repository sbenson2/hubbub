// Hubbub patch: libwebrtc adapter for the capture pipeline. Registered with
// RTCAudioProcessing::SetCapturePostProcessing; runs after AEC/NS/AGC.
#ifndef HUBBUB_CAPTURE_PROCESSOR_H_
#define HUBBUB_CAPTURE_PROCESSOR_H_

#include <atomic>
#include <memory>
#include <vector>

#include "hubbub_audio.h"
#include "rtc_audio_processing.h"

namespace hubbub {

class CaptureProcessor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  using LevelsCallback = CapturePipeline::LevelsCallback;

  void SetRnnoiseEnabled(bool on) {
    rnnoise_ = on;
    for (auto& p : pipes_) p->SetRnnoiseEnabled(on);
  }
  void SetGain(float g) {
    gain_ = g;
    for (auto& p : pipes_) p->SetGain(g);
  }
  void SetLevelsCallback(LevelsCallback cb) { cb_ = std::move(cb); }

  int rate() const { return rate_; }
  int channels() const { return channels_; }
  long calls() const { return calls_; }
  int last_bands() const { return bands_; }
  int last_frames() const { return frames_; }
  bool rnnoise() const { return rnnoise_; }
  float gain() const { return gain_; }

  // CustomProcessing. The APM calls Initialize and Process from its capture
  // thread; the setters above may race with it, which is why the pipeline
  // keeps its settings in atomics.
  void Initialize(int sample_rate_hz, int num_channels) override {
    rate_ = sample_rate_hz;
    channels_ = num_channels < 1 ? 1 : num_channels;
    pipes_.clear();
    for (int c = 0; c < channels_; ++c) {
      auto p = std::make_unique<CapturePipeline>();
      p->Initialize(sample_rate_hz, 1);
      p->SetRnnoiseEnabled(rnnoise_);
      p->SetGain(gain_);
      // only channel 0 publishes the meter
      if (c == 0) p->SetLevelsCallback(cb_);
      pipes_.push_back(std::move(p));
    }
  }
  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override {
    ++calls_;
    bands_ = num_bands;
    frames_ = num_frames;
    if (pipes_.empty() || num_bands != 1 || num_frames <= 0) return;
    // Mono is the layout seen on Windows (frames == buffer_size). Several
    // channels are assumed to be stored one after another (planar).
    int ch = buffer_size / num_frames;
    if (ch < 1) return;
    if (ch > (int)pipes_.size()) ch = (int)pipes_.size();
    for (int c = 0; c < ch; ++c)
      pipes_[c]->Process(buffer + (size_t)c * num_frames, num_frames);
  }
  void Reset(int new_rate) override {
    if (new_rate != rate_) Initialize(new_rate, channels_);
  }
  void Release() override { pipes_.clear(); }

 private:
  std::vector<std::unique_ptr<CapturePipeline>> pipes_;
  LevelsCallback cb_;
  std::atomic<bool> rnnoise_{false};
  std::atomic<float> gain_{1.f};
  int rate_ = 0, channels_ = 1;
  std::atomic<long> calls_{0};
  std::atomic<int> bands_{0}, frames_{0};
};

}  // namespace hubbub

#endif  // HUBBUB_CAPTURE_PROCESSOR_H_
