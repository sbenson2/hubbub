// Hubbub patch: libwebrtc adapter for the capture pipeline. Registered with
// RTCAudioProcessing::SetCapturePostProcessing; runs after AEC/NS/AGC.
//
// Threads: libwebrtc calls Initialize/Process/Reset/Release from its capture
// thread. The setters and getters are called from the platform thread. They
// only touch atomics (settings_, the counters, levels_); pipes_ belongs to the
// audio thread alone.
//
// Buffer layout, as measured with hubbub_test/apm_probe against libwebrtc m150
// (see HUBBUB_PATCHES.md):
//   Windows  Initialize(48000, 1); Process(bands=3, frames=480, size=480) with Hubbub's
//            build (third_party/libwebrtc-hubbub); the stock prebuilt gives
//            Initialize(16000, 1); Process(bands=1, frames=160, size=160).
//   Linux    Initialize(48000, 1); Process(bands=3, frames=480, size=480).
// |num_frames| is the full-band 10 ms frame count (rate / 100) even when
// |num_bands| is 3, and the buffer then holds the merged full-band signal (a
// 10 kHz test tone arrives intact), so a block is processed as full band
// whatever |num_bands| says. Several channels are taken from Initialize and
// assumed to follow one another (planar, |num_frames| apart). A block that
// does not look like that is passed through untouched, counted in skipped()
// and logged (first one per Initialize); it is never skipped silently.
#ifndef HUBBUB_CAPTURE_PROCESSOR_H_
#define HUBBUB_CAPTURE_PROCESSOR_H_

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "hubbub_audio.h"
#include "hubbub_tap.h"
#include "rtc_audio_processing.h"

namespace hubbub {

// One line on stderr, for the owner's live run. (The same facts also reach the
// app through the levels event, see flutter_webrtc_base.cc.)
inline std::atomic<bool>& LogEnabled() {
  static std::atomic<bool> on{true};  // tests switch it off for loops
  return on;
}
inline void LogLine(const char* fmt, ...) {
  if (!LogEnabled().load()) return;
  char line[320];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  std::fprintf(stderr, "hubbub: %s\n", line);
  std::fflush(stderr);
}

class CaptureProcessor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  enum SkipReason {
    kNotSkipped = 0,
    kNoPipelines,    // before Initialize or after Release
    kBadFrames,      // num_frames is not the full-band frame count
    kSplitBands,     // num_frames * num_bands is the full-band count: bands apart
    kBadArguments,   // null buffer or non-positive frames
  };

  ~CaptureProcessor() override { Shutdown(); }

  // Settings: any thread, atomics only.
  void SetRnnoiseEnabled(bool on) { settings_.rnnoise.store(on); }
  // False (and no change) for NaN and infinity.
  bool SetGain(float g) { return settings_.SetGain(g); }
  // Test-only A/B switch (hidden plugin method hubbubSetTailMode). Out-of-range
  // numbers are clamped; the floor to -25..-15 dB and the hold to 150..250 ms.
  void SetTailMode(bool classic, float floor_db, float hold_ms) {
    settings_.tail_classic.store(classic);
    settings_.tail_floor_db.store(floor_db < -25.f ? -25.f : floor_db > -15.f ? -15.f : floor_db);
    settings_.tail_hold_ms.store(hold_ms < 150.f ? 150.f : hold_ms > 250.f ? 250.f : hold_ms);
  }
  bool rnnoise() const { return settings_.rnnoise.load(); }
  float gain() const { return settings_.gain.load(); }

  // Diagnostic taps (hubbub_tap.h), all off by default. "In" is the signal as the
  // hook receives it (after the APM's echo cancellation, noise suppression and AGC;
  // after the injected file when injecting); "out" is what leaves the hook, which is
  // what the encoder gets.
  WavTap& tap_in() { return tap_in_; }
  WavTap& tap_out() { return tap_out_; }
  WavInject& inject() { return inject_; }

  // Latest levels, written by the audio thread, polled by the publisher.
  const LevelsSlot& levels() const { return levels_; }

  // Status, for hubbubGetStatus and the levels event.
  int rate() const { return rate_.load(); }
  int channels() const { return channels_.load(); }
  long calls() const { return calls_.load(); }
  long processed() const { return processed_.load(); }
  long skipped() const { return skipped_.load(); }
  int last_bands() const { return bands_.load(); }
  int last_frames() const { return frames_.load(); }
  int last_size() const { return size_.load(); }
  int last_skip_reason() const { return skip_reason_.load(); }
  // Counts of Initialize calls, so a publisher can tell the layout changed.
  int inits() const { return inits_.load(); }
  std::string Layout() const {
    char b[128];
    std::snprintf(b, sizeof b, "rate=%d ch=%d bands=%d frames=%d size=%d", rate(),
                  channels(), last_bands(), last_frames(), last_size());
    return b;
  }
  static const char* SkipName(int r) {
    switch (r) {
      case kNoPipelines: return "no pipelines";
      case kBadFrames: return "unexpected frame count";
      case kSplitBands: return "split bands";
      case kBadArguments: return "bad arguments";
      default: return "none";
    }
  }

  // After this returns Process does nothing and no call is still inside, so
  // the object can be destroyed even if the library does not wait for an
  // in-flight Process when it is unregistered. Call before unregistering.
  void Shutdown() {
    shutdown_.store(true);
    for (int i = 0; i < 1000 && busy_.load() > 0; ++i)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    tap_in_.Stop(nullptr);
    tap_out_.Stop(nullptr);
    inject_.Unload();
  }

  // CustomProcessing (audio thread).
  void Initialize(int sample_rate_hz, int num_channels) override {
    if (shutdown_.load()) return;
    Busy busy(busy_);
    if (shutdown_.load()) return;
    int rate = sample_rate_hz > 0 ? sample_rate_hz : 48000;
    int ch = num_channels < 1 ? 1 : num_channels;
    rate_.store(rate);
    channels_.store(ch);
    inits_.fetch_add(1);
    logged_skip_ = false;
    logged_mismatch_ = false;
    LogLine("apm init rate=%d ch=%d", sample_rate_hz, num_channels);
    pipes_.clear();
    for (int c = 0; c < ch; ++c) {
      auto p = std::make_unique<CapturePipeline>();
      p->UseSettings(&settings_);
      p->Initialize(rate, 1);
      // only channel 0 publishes the meter
      if (c == 0) p->UseLevelsSlot(&levels_);
      pipes_.push_back(std::move(p));
    }
  }

  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override {
    Busy busy(busy_);
    if (shutdown_.load()) return;
    calls_.fetch_add(1, std::memory_order_relaxed);
    bands_.store(num_bands, std::memory_order_relaxed);
    frames_.store(num_frames, std::memory_order_relaxed);
    size_.store(buffer_size, std::memory_order_relaxed);
    if (!buffer || num_frames <= 0) return Skip(kBadArguments, num_bands, num_frames, buffer_size);
    if (pipes_.empty()) return Skip(kNoPipelines, num_bands, num_frames, buffer_size);
    const int full = rate_.load(std::memory_order_relaxed) / 100;
    if (num_frames != full) {
      // bands stored apart cannot be handled through one pointer
      return Skip(num_bands > 1 && num_frames * num_bands == full ? kSplitBands
                                                                   : kBadFrames,
                  num_bands, num_frames, buffer_size);
    }
    // The channel count is Initialize's. If buffer_size says otherwise, say so
    // once, and still follow Initialize.
    const int ch = (int)pipes_.size();
    if (buffer_size < ch * num_frames && !logged_mismatch_) {
      logged_mismatch_ = true;
      LogLine("apm layout: buffer_size=%d holds fewer than ch=%d x frames=%d; using Initialize's channel count",
              buffer_size, ch, num_frames);
    }
    // Diagnostics (off: three relaxed loads).
    if (inject_.active()) inject_.Fill(buffer, (size_t)num_frames, (size_t)ch, rate_.load(std::memory_order_relaxed));
    if (tap_in_.active()) tap_in_.PushFloat(buffer, (size_t)num_frames, rate_.load(std::memory_order_relaxed));
    for (int c = 0; c < ch; ++c)
      pipes_[c]->Process(buffer + (size_t)c * num_frames, (size_t)num_frames);
    if (tap_out_.active()) tap_out_.PushFloat(buffer, (size_t)num_frames, rate_.load(std::memory_order_relaxed));
    processed_.fetch_add(1, std::memory_order_relaxed);
  }

  void Reset(int new_rate) override {
    if (new_rate != rate_.load()) Initialize(new_rate, channels_.load());
  }
  void Release() override {
    Busy busy(busy_);
    pipes_.clear();
  }

 private:
  struct Busy {
    explicit Busy(std::atomic<int>& b) : b_(b) { b_.fetch_add(1); }
    ~Busy() { b_.fetch_sub(1); }
    std::atomic<int>& b_;
  };

  void Skip(SkipReason why, int bands, int frames, int size) {
    skipped_.fetch_add(1, std::memory_order_relaxed);
    skip_reason_.store(why, std::memory_order_relaxed);
    if (!logged_skip_) {
      logged_skip_ = true;
      LogLine("apm skipping blocks (%s): rate=%d ch=%d bands=%d frames=%d size=%d", SkipName(why),
              rate_.load(), channels_.load(), bands, frames, size);
    }
  }

  CaptureSettings settings_;
  WavTap tap_in_, tap_out_;
  WavInject inject_;
  LevelsSlot levels_;
  std::vector<std::unique_ptr<CapturePipeline>> pipes_;  // audio thread only
  bool logged_skip_ = false, logged_mismatch_ = false;   // audio thread only
  std::atomic<bool> shutdown_{false};
  std::atomic<int> busy_{0};
  std::atomic<int> rate_{0}, channels_{1};
  std::atomic<int> bands_{0}, frames_{0}, size_{0}, skip_reason_{0}, inits_{0};
  std::atomic<long> calls_{0}, processed_{0}, skipped_{0};
};

}  // namespace hubbub

#endif  // HUBBUB_CAPTURE_PROCESSOR_H_
