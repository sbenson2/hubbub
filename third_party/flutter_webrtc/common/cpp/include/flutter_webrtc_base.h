#ifndef FLUTTER_WEBRTC_BASE_HXX
#define FLUTTER_WEBRTC_BASE_HXX

#include "flutter_common.h"

#include <string.h>
#include <atomic>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

#include "libwebrtc.h"

#include "rtc_audio_device.h"
#include "rtc_audio_processing.h"
// Hubbub patch: capture post-processor (RNNoise, input gain, peak meter).
#include "hubbub_capture_processor.h"
#include "hubbub_render_processor.h"
#include "hubbub_track_tap.h"
#include "rtc_desktop_device.h"
#include "rtc_dtmf_sender.h"
#include "rtc_frame_cryptor.h"
#include "rtc_media_stream.h"
#include "rtc_media_track.h"
#include "rtc_mediaconstraints.h"
#include "rtc_peerconnection.h"
#include "rtc_peerconnection_factory.h"
#include "rtc_video_device.h"

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class FlutterVideoRenderer;
class FlutterRTCDataChannelObserver;
class FlutterPeerConnectionObserver;

class FlutterWebRTCBase {
 public:
  friend class FlutterMediaStream;
  friend class FlutterPeerConnection;
  friend class FlutterVideoRendererManager;
  friend class FlutterDataChannel;
  friend class FlutterPeerConnectionObserver;
  friend class FlutterScreenCapture;
  friend class FlutterFrameCryptor;
  friend class FlutterDataPacketCryptor;
  enum ParseConstraintType { kMandatory, kOptional };

 public:
  FlutterWebRTCBase(BinaryMessenger* messenger,
                    TextureRegistrar* textures,
                    TaskRunner* task_runner);
  ~FlutterWebRTCBase();

  // Initializes WebRTC and creates the peer connection factory the first time
  // it is needed, applying the process global field trials that the
  // `initialize()` options ask for. Field trials are read when the factory is
  // created, so only the first call decides them; later calls are no-ops.
  void EnsureWebRTCInitialized(bool enable_warp = false,
                               bool zero_playout_delay = false);

  virtual scoped_refptr<RTCAudioProcessing> audio_processing() {
    EnsureWebRTCInitialized();
    return audio_processing_;
  }

  virtual scoped_refptr<RTCMediaTrack> MediaTrackForId(const std::string& id);

  std::string GenerateUUID();

  RTCPeerConnection* PeerConnectionForId(const std::string& id);

  void RemovePeerConnectionForId(const std::string& id);

  void RemoveMediaTrackForId(const std::string& id);

  FlutterPeerConnectionObserver* PeerConnectionObserversForId(
      const std::string& id);

  void RemovePeerConnectionObserversForId(const std::string& id);

  scoped_refptr<RTCMediaStream> MediaStreamForId(
      const std::string& id,
      std::string ownerTag = std::string());

  void RemoveStreamForId(const std::string& id);

  bool ParseConstraints(const EncodableMap& constraints,
                        RTCConfiguration* configuration);

  scoped_refptr<RTCMediaConstraints> ParseMediaConstraints(
      const EncodableMap& constraints);

  bool ParseRTCConfiguration(const EncodableMap& map,
                             RTCConfiguration& configuration);

  scoped_refptr<RTCMediaTrack> MediaTracksForId(const std::string& id);

  void RemoveTracksForId(const std::string& id);

  EventChannelProxy* event_channel();

  libwebrtc::scoped_refptr<libwebrtc::RTCRtpSender> GetRtpSenderById(
      RTCPeerConnection* pc,
      std::string id);

  libwebrtc::scoped_refptr<libwebrtc::RTCRtpReceiver> GetRtpReceiverById(
      RTCPeerConnection* pc,
      std::string id);

  libwebrtc::scoped_refptr<libwebrtc::KeyProvider> GetKeyProviderForId(
      const std::string& keyProviderId);

 private:
  void ParseConstraints(const EncodableMap& src,
                        scoped_refptr<RTCMediaConstraints> mediaConstraints,
                        ParseConstraintType type = kMandatory);

  bool CreateIceServers(const EncodableList& iceServersArray,
                        IceServer* ice_servers);

 protected:
  bool webrtc_initialized_ = false;
  // Whether `enableWARP` was requested; peer connections created afterwards
  // default to DSCP marking. See EnsureWebRTCInitialized().
  bool warp_enabled_ = false;
  scoped_refptr<RTCPeerConnectionFactory> factory_;
  scoped_refptr<RTCAudioDevice> audio_device_;
  scoped_refptr<RTCVideoDevice> video_device_;
  scoped_refptr<RTCDesktopDevice> desktop_device_;
  scoped_refptr<RTCAudioProcessing> audio_processing_;
  // Hubbub patch: registered with audio_processing_ as capture post-processor.
  std::unique_ptr<hubbub::CaptureProcessor> hubbub_processor_;
  // Hubbub patch: polls the processor's lock-free levels slot about 20 times a
  // second and has the platform thread publish them on the event channel, so
  // the audio thread never builds a map or calls the channel.
  std::thread hubbub_publisher_;
  std::atomic<bool> hubbub_stop_{false};
  // Tasks queued on the platform thread check this before touching |this|.
  std::shared_ptr<std::atomic<bool>> hubbub_alive_ =
      std::make_shared<std::atomic<bool>>(true);
  void HubbubPublishLoop();
  // Hubbub patch: playout hook (mix tap, test mute); created on first use, never unregistered.
  std::unique_ptr<hubbub::RenderProcessor> hubbub_render_;
  hubbub::RenderProcessor* HubbubRender();
  // Hubbub patch: per-track diagnostic recorders (hubbubRecordTrack), platform thread only.
  std::map<std::string, std::unique_ptr<hubbub::TrackTap>> hubbub_track_taps_;
  RTCConfiguration configuration_;

  std::map<std::string, scoped_refptr<libwebrtc::KeyProvider>> key_providers_;
  std::map<std::string, scoped_refptr<RTCPeerConnection>> peerconnections_;
  std::map<std::string, scoped_refptr<RTCMediaStream>> local_streams_;
  std::map<std::string, scoped_refptr<RTCMediaTrack>> local_tracks_;
  std::map<std::string, scoped_refptr<RTCVideoCapturer>> video_capturers_;
  std::map<int64_t, std::shared_ptr<FlutterVideoRenderer>> renders_;
  std::map<std::string, std::shared_ptr<FlutterRTCDataChannelObserver>>
      data_channel_observers_;
  std::map<std::string, std::shared_ptr<FlutterPeerConnectionObserver>>
      peerconnection_observers_;
  mutable std::mutex mutex_;

  void lock() { mutex_.lock(); }
  void unlock() { mutex_.unlock(); }

 protected:
  BinaryMessenger* messenger_;
  TaskRunner* task_runner_;
  TextureRegistrar* textures_;
  std::unique_ptr<EventChannelProxy> event_channel_;
};

}  // namespace flutter_webrtc_plugin

#endif  // !FLUTTER_WEBRTC_BASE_HXX
