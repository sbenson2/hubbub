// Hubbub patch: render-side (playout) hook for diagnostics, registered lazily with
// RTCAudioProcessing::SetRenderPreProcessing the first time the app asks for it (never
// otherwise, so a normal call is untouched). It sees the final playout mix of all remote
// participants, after the per-track decode and mixing and just before the audio device:
//   * a tap writes that mix to a 48 kHz WAV (hubbub_tap.h),
//   * "mute" zeroes it, so an automated test can receive audio without playing it.
// Like the capture processor it is never unregistered (the prebuilt libwebrtc crashes when
// a processor is unregistered); Shutdown() makes it inert and it is leaked on purpose.
#ifndef HUBBUB_RENDER_PROCESSOR_H_
#define HUBBUB_RENDER_PROCESSOR_H_

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>

#include "hubbub_capture_processor.h"  // LogLine
#include "hubbub_tap.h"
#include "rtc_audio_processing.h"

namespace hubbub {

class RenderProcessor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  ~RenderProcessor() override { Shutdown(); }

  WavTap& tap() { return tap_; }
  void SetMuted(bool on) { muted_.store(on); }
  bool muted() const { return muted_.load(); }
  int rate() const { return rate_.load(); }
  int channels() const { return channels_.load(); }
  long calls() const { return calls_.load(); }

  void Shutdown() {
    shutdown_.store(true);
    for (int i = 0; i < 1000 && busy_.load() > 0; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    tap_.Stop(nullptr);
  }

  void Initialize(int sample_rate_hz, int num_channels) override {
    rate_.store(sample_rate_hz > 0 ? sample_rate_hz : 48000);
    channels_.store(num_channels < 1 ? 1 : num_channels);
    LogLine("render init rate=%d ch=%d", sample_rate_hz, num_channels);
  }

  void Process(int num_bands, int num_frames, int buffer_size, float* buffer) override {
    busy_.fetch_add(1);
    if (!shutdown_.load() && buffer && num_frames > 0) {
      calls_.fetch_add(1, std::memory_order_relaxed);
      (void)num_bands;
      if (tap_.active()) tap_.PushFloat(buffer, (size_t)num_frames, rate_.load(std::memory_order_relaxed));
      if (muted_.load(std::memory_order_relaxed)) {
        size_t n = buffer_size > 0 ? (size_t)buffer_size : (size_t)num_frames * (size_t)channels_.load();
        std::memset(buffer, 0, n * sizeof(float));
      }
    }
    busy_.fetch_sub(1);
  }

  void Reset(int new_rate) override {
    if (new_rate > 0) rate_.store(new_rate);
  }
  void Release() override {}

 private:
  WavTap tap_;
  std::atomic<bool> muted_{false}, shutdown_{false};
  std::atomic<int> busy_{0}, rate_{48000}, channels_{1};
  std::atomic<long> calls_{0};
};

}  // namespace hubbub

#endif  // HUBBUB_RENDER_PROCESSOR_H_
