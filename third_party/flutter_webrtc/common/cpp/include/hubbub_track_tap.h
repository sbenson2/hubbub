// Hubbub patch: records one audio track (a remote participant's decoded audio, or
// a local track) to a WAV file through RTCAudioTrack::AddSink. Off unless started.
#ifndef HUBBUB_TRACK_TAP_H_
#define HUBBUB_TRACK_TAP_H_

#include <string>

#include "hubbub_tap.h"
#include "rtc_audio_track.h"

namespace hubbub {

class TrackTap : public libwebrtc::AudioTrackSink {
 public:
  ~TrackTap() override { Stop(nullptr); }

  bool Start(libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track, const std::string& path,
             std::string* err) {
    if (!tap_.Start(path, err)) return false;
    track_ = track;
    track_->AddSink(this);
    return true;
  }
  bool Stop(TapStats* out) {
    if (track_) {
      track_->RemoveSink(this);
      track_ = nullptr;
    }
    return tap_.Stop(out);
  }
  int calls() const { return calls_.load(); }

  // Audio thread of the track.
  void OnData(const void* audio_data, int bits_per_sample, int sample_rate,
              size_t number_of_channels, size_t number_of_frames) override {
    calls_.fetch_add(1, std::memory_order_relaxed);
    if (bits_per_sample == 16)
      tap_.PushPcm16((const int16_t*)audio_data, number_of_frames, sample_rate, number_of_channels);
  }

 private:
  WavTap tap_;
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track_;
  std::atomic<int> calls_{0};
};

}  // namespace hubbub

#endif  // HUBBUB_TRACK_TAP_H_
