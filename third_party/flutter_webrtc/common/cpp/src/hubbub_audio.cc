// Hubbub patch: capture-side audio pipeline. See hubbub_audio.h.
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif
#include "hubbub_audio.h"

#include <algorithm>
#include <cmath>
#include <numeric>

extern "C" {
#include "rnnoise.h"
}

namespace hubbub {

namespace {
constexpr float kKnee = 0.85f * kFullScale;
constexpr float kMaxOut = 32767.f;
constexpr int kRnnoiseRate = 48000;
constexpr int kRnnoiseFrame = 480;
constexpr float kClipLevel = 0.98f * kFullScale;
}  // namespace

float SoftLimit(float x) {
  float a = std::fabs(x);
  if (a <= kKnee) return x;
  float room = kFullScale - kKnee;
  float y = kKnee + room * std::tanh((a - kKnee) / room);
  // tanh saturates at exactly 1.0 in float for huge inputs; stay below it
  y = std::min(y, kFullScale - 0.5f);
  return x < 0 ? -y : y;
}

RationalResampler::RationalResampler(int in_rate, int out_rate) {
  int g = std::gcd(in_rate, out_rate);
  a_ = in_rate / g;
  b_ = out_rate / g;
  // Cutoff at 45% of the lower rate, 8 zero crossings each side.
  double fc = 0.45 * std::min(in_rate, out_rate);
  double zero_cross_in = in_rate / (2.0 * fc);  // input samples per crossing
  half_ = (int)std::ceil(8.0 * zero_cross_in);
  phases_.assign(b_, std::vector<float>(2 * half_));
  for (int p = 0; p < b_; ++p) {
    double frac = (double)p / b_;  // output sits frac after input sample base
    double sum = 0;
    for (int j = -half_ + 1; j <= half_; ++j) {
      double t = j - frac;  // offset of tap j from the output position
      double x = 2.0 * fc / in_rate * t;
      double s = std::fabs(x) < 1e-12 ? 1.0 : std::sin(M_PI * x) / (M_PI * x);
      double w = 0.5 + 0.5 * std::cos(M_PI * t / (half_ + 1));  // Hann
      double h = s * w;
      phases_[p][j + half_ - 1] = (float)h;
      sum += h;
    }
    for (auto& h : phases_[p]) h = (float)(h / sum);  // unity DC gain
  }
  Prime();
}

void RationalResampler::Prime() {
  buf_.assign(half_, 0.f);
  start_ = 0;
  total_ = half_;
  k_ = 0;
}

void RationalResampler::Reset() { Prime(); }

void RationalResampler::Process(const float* in, size_t n,
                                std::vector<float>& out) {
  buf_.insert(buf_.end(), in, in + n);
  total_ += (int64_t)n;
  // Output k sits at input position k*a/b measured from the primed origin;
  // taps cover [base-half+1, base+half] (offset by the priming zeros).
  for (;;) {
    int64_t num = k_ * a_;
    int64_t base = num / b_ + half_;  // absolute index incl. priming zeros
    int p = (int)(num % b_);
    if (base + half_ >= total_) break;
    const float* h = phases_[p].data();
    const float* x = buf_.data() + (base - half_ + 1 - start_);
    float acc = 0;
    for (int j = 0; j < 2 * half_; ++j) acc += h[j] * x[j];
    out.push_back(acc);
    ++k_;
  }
  // Drop history that no later output can use.
  int64_t keep_from = (k_ * a_) / b_ + half_ - half_ + 1;
  if (keep_from - start_ > 4096) {
    buf_.erase(buf_.begin(), buf_.begin() + (keep_from - start_));
    start_ = keep_from;
  }
}

CapturePipeline::CapturePipeline() = default;

CapturePipeline::~CapturePipeline() {
  if (st_) rnnoise_destroy(st_);
}

void CapturePipeline::Initialize(int sample_rate, int channels) {
  (void)channels;
  rate_ = sample_rate > 0 ? sample_rate : 48000;
  window_len_ = std::max<size_t>(1, rate_ / 20);
  window_pos_ = 0;
  pre_peak_ = post_peak_ = 0;
  blocks_ = clipped_blocks_ = 0;
  applied_gain_ = gain_.load();
  ResetDenoise();
  denoise_active_ = false;
}

void CapturePipeline::ResetDenoise() {
  if (st_) rnnoise_destroy(st_);
  st_ = rnnoise_create(nullptr);
  chunker_.Clear();
  fifo_.clear();
  speech_sum_ = 0;
  speech_n_ = 0;
  if (rate_ != kRnnoiseRate) {
    up_ = std::make_unique<RationalResampler>(rate_, kRnnoiseRate);
    down_ = std::make_unique<RationalResampler>(kRnnoiseRate, rate_);
  } else {
    up_.reset();
    down_.reset();
  }
}

// Runs RNNoise on |samples| in place. Output is delayed by the resampler's
// group delay (about 1 ms at 16/32 kHz); when too little is ready yet (the
// first block) the front of the block is zero filled.
void CapturePipeline::RunDenoise(float* samples, size_t n) {
  const float* in48 = samples;
  size_t n48 = n;
  if (up_) {
    scratch_.clear();
    up_->Process(samples, n, scratch_);
    in48 = scratch_.data();
    n48 = scratch_.size();
  }
  out48_.clear();
  chunker_.Push(in48, n48, [&](const float* frame) {
    float tmp[kRnnoiseFrame];
    float vad = rnnoise_process_frame(st_, tmp, frame);
    speech_sum_ += vad;
    ++speech_n_;
    out48_.insert(out48_.end(), tmp, tmp + kRnnoiseFrame);
  });
  if (down_) {
    down_->Process(out48_.data(), out48_.size(), fifo_);
  } else {
    fifo_.insert(fifo_.end(), out48_.begin(), out48_.end());
  }
  size_t have = std::min(fifo_.size(), n);
  size_t pad = n - have;
  std::fill(samples, samples + pad, 0.f);
  std::copy(fifo_.begin(), fifo_.begin() + have, samples + pad);
  fifo_.erase(fifo_.begin(), fifo_.begin() + have);
}

void CapturePipeline::Process(float* x, size_t n) {
  // true pre-gain peak (what the device and APM delivered)
  float pre = 0;
  for (size_t i = 0; i < n; ++i) pre = std::max(pre, std::fabs(x[i]));

  bool want = rnnoise_.load();
  if (want && !denoise_active_) {
    ResetDenoise();
    denoise_active_ = true;
  } else if (!want && denoise_active_) {
    denoise_active_ = false;
    fifo_.clear();
  }
  if (denoise_active_) RunDenoise(x, n);

  float target = gain_.load();
  if (target == 1.f && applied_gain_ == 1.f) {
    for (size_t i = 0; i < n; ++i)
      x[i] = std::max(-kFullScale, std::min(kMaxOut, x[i]));
  } else {
    float g = applied_gain_;
    float step = (target - applied_gain_) / (float)std::max<size_t>(1, n);
    for (size_t i = 0; i < n; ++i) {
      g += step;
      float y = SoftLimit(x[i] * g);
      x[i] = std::max(-kMaxOut, std::min(kMaxOut, y));
    }
    applied_gain_ = target;
  }
  float post = 0;
  for (size_t i = 0; i < n; ++i) post = std::max(post, std::fabs(x[i]));

  pre_peak_ = std::max(pre_peak_, pre);
  ++blocks_;
  if (pre >= kClipLevel) ++clipped_blocks_;
  post_peak_ = std::max(post_peak_, post);
  window_pos_ += n;
  if (window_pos_ >= window_len_) {
    window_pos_ -= window_len_;
    if (cb_) {
      Levels l;
      l.pre = std::min(1.f, pre_peak_ / kFullScale);
      l.post = std::min(1.f, post_peak_ / kFullScale);
      l.clip = blocks_ > 0 ? (float)clipped_blocks_ / (float)blocks_ : 0.f;
      l.speech = (denoise_active_ && speech_n_ > 0) ? speech_sum_ / speech_n_ : -1.f;
      cb_(l);
    }
    pre_peak_ = post_peak_ = 0;
    blocks_ = clipped_blocks_ = 0;
    speech_sum_ = 0;
    speech_n_ = 0;
  }
}

}  // namespace hubbub
