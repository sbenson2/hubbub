// Hubbub runtime proof: does the prebuilt libwebrtc call a CustomProcessing
// registered with SetCapturePostProcessing? Runs two peer connections in one
// process (loopback) so the audio send stream starts and the capture path
// (ADM -> APM -> post processor) runs. No GUI. Prints "hubbub: probe ..." lines.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <thread>
#include <vector>
#include <string>

#include "hubbub_capture_processor.h"
#include "libwebrtc.h"
#include "rtc_logging.h"
#include "rtc_audio_device.h"
#include "rtc_audio_track.h"
#include "rtc_audio_processing.h"
#include "rtc_peerconnection.h"
#include "rtc_peerconnection_factory.h"

using namespace libwebrtc;

namespace {

std::atomic<long> g_calls{0};
std::atomic<long> g_sink_calls{0};
std::atomic<int> g_sink_peak{0};

class Sink : public AudioTrackSink {
 public:
  void OnData(const void* data, int bits, int rate, size_t ch, size_t frames) override {
    g_sink_calls++;
    if (bits != 16) return;
    const int16_t* p = (const int16_t*)data;
    int peak = 0;
    for (size_t i = 0; i < ch * frames; ++i) { int v = std::abs((int)p[i]); if (v > peak) peak = v; }
    int cur = g_sink_peak.load();
    while (peak > cur && !g_sink_peak.compare_exchange_weak(cur, peak)) {}
  }
};

std::atomic<int> g_zero{0};

class Probe : public RTCAudioProcessing::CustomProcessing {
 public:
  void Initialize(int rate, int ch) override {
    std::printf("hubbub: probe Initialize rate=%d channels=%d\n", rate, ch);
  }
  void Process(int bands, int frames, int size, float* buf) override {
    long n = ++g_calls;
    if (n <= 3 || n % 100 == 0) {
      float peak = 0;
      for (int i = 0; i < size; ++i) peak = std::fmax(peak, std::fabs(buf[i]));
      std::printf("hubbub: probe Process #%ld bands=%d frames=%d size=%d peak=%g\n",
                  n, bands, frames, size, peak);
    }
    if (g_zero.load())
      for (int i = 0; i < size; ++i) buf[i] = 0.f;
  }
  void Reset(int rate) override {
    std::printf("hubbub: probe Reset rate=%d\n", rate);
  }
  void Release() override { std::printf("hubbub: probe Release\n"); }
};

class Obs : public RTCPeerConnectionObserver {
 public:
  RTCPeerConnection* other = nullptr;
  const char* name = "";
  void OnSignalingState(RTCSignalingState) override {}
  void OnPeerConnectionState(RTCPeerConnectionState s) override {
    std::printf("hubbub: probe %s pcstate=%d\n", name, (int)s);
  }
  void OnIceGatheringState(RTCIceGatheringState s) override { std::printf("hubbub: probe %s gather=%d\n", name, (int)s); }
  void OnIceConnectionState(RTCIceConnectionState s) override {
    std::printf("hubbub: probe %s ice=%d\n", name, (int)s);
  }
  void OnIceCandidate(scoped_refptr<RTCIceCandidate> c) override {
    std::printf("hubbub: probe %s cand %s\n", name, c->candidate().c_string());
    if (other)
      other->AddCandidate(c->sdp_mid(), c->sdp_mline_index(), c->candidate());
  }
  void OnAddStream(scoped_refptr<RTCMediaStream>) override {}
  void OnRemoveStream(scoped_refptr<RTCMediaStream>) override {}
  void OnDataChannel(scoped_refptr<RTCDataChannel>) override {}
  void OnRenegotiationNeeded() override {}
  void OnTrack(scoped_refptr<RTCRtpTransceiver>) override {}
  void OnAddTrack(vector<scoped_refptr<RTCMediaStream>>,
                  scoped_refptr<RTCRtpReceiver>) override {}
  void OnRemoveTrack(scoped_refptr<RTCRtpReceiver>) override {}
};

std::atomic<bool> g_done{false};
std::string g_sdp, g_type;
scoped_refptr<RTCAudioTrack> g_track;
RTCPeerConnection* g_a;
RTCPeerConnection* g_b;

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  bool zero = argc > 1 && std::string(argv[1]) == "zero";
  g_zero = zero ? 1 : 0;
  if (std::getenv("PROBE_LOG")) {
    LibWebRTCLogging::setMinDebugLogLevel(RTCLoggingSeverity::Info);
    LibWebRTCLogging::setLogSink(RTCLoggingSeverity::Info, [](const string& m) {
      std::printf("webrtc: %s", m.c_string());
    });
  }
  LibWebRTC::Initialize();
  auto factory = LibWebRTC::CreateRTCPeerConnectionFactory();
  factory->Initialize();
  auto adev = factory->GetAudioDevice();
  std::printf("hubbub: probe recording devices=%d playout devices=%d\n",
              (int)adev->RecordingDevices(), (int)adev->PlayoutDevices());
  auto apm = factory->GetAudioProcessing();
  Probe probe;
  hubbub::CaptureProcessor real;
  bool use_real = argc > 1 && std::string(argv[1]) == "real";
  if (use_real) {
    real.SetRnnoiseEnabled(true);
    real.SetGain(1.5f);
    real.SetLevelsCallback([](const hubbub::Levels& l) {
      static int n = 0;
      if (++n % 20 == 1)
        std::printf("hubbub: probe levels pre=%.3f post=%.3f speech=%.2f\n", l.pre, l.post, l.speech);
    });
    apm->SetCapturePostProcessing(&real);
  } else {
    apm->SetCapturePostProcessing(&probe);
  }
  std::printf("hubbub: probe registered (zero=%d)\n", (int)zero);

  RTCAudioOptions opts;
  auto src = factory->CreateAudioSource("mic", RTCAudioSource::kMicrophone, opts);
  auto track = factory->CreateAudioTrack(src, "audio0");
  Sink sink;
  track->AddSink(&sink);

  RTCConfiguration cfg;
  if (argc > 2) { cfg.disable_ipv6 = true; cfg.disable_link_local_networks = true; cfg.candidate_network_policy = CandidateNetworkPolicy::kCandidateNetworkPolicyAll; cfg.ice_servers[0].uri = string("stun:stun.l.google.com:19302"); }
  Obs oa, ob;
  oa.name = "A";
  ob.name = "B";
  auto a = factory->Create(cfg, RTCMediaConstraints::Create());
  auto b = factory->Create(cfg, RTCMediaConstraints::Create());
  g_a = a.get();
  g_b = b.get();
  oa.other = g_b;
  ob.other = g_a;
  a->RegisterRTCPeerConnectionObserver(&oa);
  b->RegisterRTCPeerConnectionObserver(&ob);
  // B (offerer) sends a custom (non-device) source, so A gets a receive stream
  // and starts playout first. The Windows built-in AEC refuses to start the
  // microphone before playout runs. A then adds the microphone track to the
  // transceiver it was offered and answers.
  auto csrc = factory->CreateAudioSource("c", RTCAudioSource::kCustom, opts);
  auto ctrack = factory->CreateAudioTrack(csrc, "audio1");
  std::vector<string> sids{string("s0")};
  b->AddTrack(ctrack, vector<string>(sids));
  g_track = track;
  b->CreateOffer(
      [](const string sdp, const string type) {
        g_b->SetLocalDescription(sdp, type, [] {}, [](const char* e) {
          std::printf("hubbub: probe B setLocal fail %s\n", e);
        });
        g_a->SetRemoteDescription(sdp, type, [] {
          std::printf("hubbub: probe A remote set\n");
          std::vector<string> ids{string("s1")};
          g_a->AddTrack(g_track, vector<string>(ids));
          g_a->CreateAnswer(
              [](const string sdp2, const string type2) {
                g_a->SetLocalDescription(sdp2, type2, [] { std::printf("hubbub: probe A local set\n"); }, [](const char* e) {
                  std::printf("hubbub: probe A setLocal fail %s\n", e);
                });
                g_b->SetRemoteDescription(sdp2, type2, [] {}, [](const char*) {});
              },
              [](const char* e) { std::printf("hubbub: probe answer fail %s\n", e); },
              RTCMediaConstraints::Create());
        }, [](const char* e) { std::printf("hubbub: probe A setRemote fail %s\n", e); });
      },
      [](const char* e) { std::printf("hubbub: probe offer fail %s\n", e); },
      RTCMediaConstraints::Create());

  for (int i = 0; i < 80; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (i % 10 == 9)
      std::printf("hubbub: probe t=%.1fs calls=%ld\n", (i + 1) / 10.0,
                  g_calls.load());
  }
  {
    a->GetStats(
        [](const vector<scoped_refptr<MediaRTCStats>> reports) {
          for (size_t i = 0; i < reports.size(); ++i) {
            auto r = reports[i];
            if (r->type().std_string() == "media-source")
              std::printf("hubbub: probe stats %s\n", r->ToJson().c_string());
          }
        },
        [](const char* e) { std::printf("hubbub: probe stats fail %s\n", e); });
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  if (use_real)
    std::printf("hubbub: probe real processor calls=%ld rate=%d channels=%d bands=%d frames=%d\n", real.calls(), real.rate(), real.channels(), real.last_bands(), real.last_frames());
  std::printf("hubbub: probe local sink calls=%ld peak=%d\n", g_sink_calls.load(), g_sink_peak.load());
  std::printf("hubbub: probe RESULT calls=%ld\n", use_real ? real.calls() : g_calls.load());
  apm->SetCapturePostProcessing(nullptr);
  a->Close();
  b->Close();
  std::fflush(stdout);
  std::_Exit((use_real ? real.calls() : g_calls.load()) > 0 ? 0 : 2);
}
