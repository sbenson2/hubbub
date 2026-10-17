# Hubbub research: Discord internals and one-codebase stack
Date: 2026-10-16. Method: web search/fetch only. Items marked (UNCONFIRMED) were not verified from a fetched source. Sources dated before 2024 are marked (STALE?).

## PART A: How Discord works

### A1. Gateway and REST
- Gateway is a WebSocket; URL from GET /gateway or /gateway/bot. Hello (op 10) gives heartbeat_interval; client waits interval*jitter then sends op 1 heartbeats with last seq; server ACKs op 11; missing ACK = zombie connection, reconnect. https://docs.discord.com/developers/events/gateway
- Identify (op 2) carries token, intents, properties; Ready returns session_id and resume_gateway_url. Resume (op 6) replays missed events. Same page.
- Intents are bit flags that filter which events you get; privileged ones: GUILD_MEMBERS, GUILD_PRESENCES, MESSAGE_CONTENT. Same page.
- Sharding: shard=[id,n], guild routing (guild_id >> 22) % n, 2500 guilds per shard. Rate limit 120 events/60 s per connection. Same page. (Bot-facing; matters only at huge scale.)
- Encoding JSON or ETF; transport compression zlib-stream or zstd-stream. Same page.
- Sept 2024 post: gateway bandwidth cut about 40% by switching zlib to streaming zstd and by "Passive Sessions V2" (send deltas, not snapshots; share of that dispatch from ~35% to ~5%). Server is Elixir on BEAM. https://discord.com/blog/how-discord-reduced-websocket-traffic-by-40-percent
- Presence: set in Identify or via update-presence; PRESENCE_UPDATE needs the privileged intent. Detail beyond that not fetched. (UNCONFIRMED details)
- REST: versioned (v10 in gateway example); permission values are strings of big integers. https://docs.discord.com/developers/topics/permissions . REST shape in general not fetched; use public docs at https://docs.discord.com/developers for reference.

### A2. Voice architecture
- 2018 post (STALE?): signaling in Elixir; each client has a second WebSocket to a voice server; etcd for service discovery, Guilds service picks least-loaded server in region; homegrown C++ SFU; no ICE, clients talk straight to the media relay and ping to keep NAT open; native clients use Salsa20 instead of DTLS/SRTP, browsers use SDP/ICE/DTLS/SRTP with SDP synthesized from a ~1 KB exchange; silence suppression (no packets during silence); native clients share a C++ engine built on libwebrtc, web uses browser WebRTC. Scale then: 850+ voice servers, 13 regions, 2.6M concurrent voice users. https://discord.com/blog/how-discord-handles-two-and-half-million-concurrent-voice-users-using-webrtc (the post does not state Opus settings.)
- Failover: client detects dead voice socket, asks gateway, Guilds reassigns to a healthy server. Same post.
- Voice gateway v8 (v<4 rejected since 2024-11-18). Flow: gateway op 4 Voice State Update -> Voice Server Update event -> WSS to voice endpoint, op 0 Identify -> op 2 Ready (SSRC, UDP ip/port, modes) -> UDP IP discovery -> op 1 Select Protocol -> op 4 Session Description (secret_key, mode). Opcodes: 3/6 heartbeat/ACK (v8 adds seq_ack), 5 Speaking (bit flags mic=1, soundshare=2, priority=4), 7 Resume, 8 Hello, 9 Resumed. https://docs.discord.com/developers/topics/voice-connections
- Media: Opus, 48 kHz stereo, RTP header (0x80, payload type 0x78) + encrypted payload. Modes: aead_aes256_gcm_rtpsize preferred, aead_xchacha20_poly1305_rtpsize required; xsalsa20 modes dropped 2024-11-18. Send five 0xF8FFFE silence frames when stopping. Same page.
- Regions: the docs do not describe selection; endpoint comes from Voice Server Update and must not be cached. Same page. Region was a per-channel setting historically (UNCONFIRMED current UI).
- Opus bitrate: 64 kbps default for non-boosted servers up to 384 kbps at top boost level, from a third-party blog only (UNCONFIRMED): https://voxbooster.com/blog/discord-audio-quality-optimization-2026/

### A3. Video and Go Live
- Mar 2024 post: codecs VP8 and H.264 with HEVC and AV1 encoders on some platforms; codec renegotiated when viewers join/leave so the streamer can encode and all viewers can decode; prefers GPU hardware encoders/decoders; encoder resolution/fps/quality follow real-time bandwidth estimate; streamer never sends more than slowest viewer can take and sends only while someone watches; capture uses the best OS method with fallbacks, some via DLL injection; audio captured from the shared process tree. Simulcast is not mentioned. https://discord.com/blog/how-it-all-goes-live-an-overview-of-discords-streaming-technology
- Tiers: free 720p/30; 1080p/60 and Source need Nitro (and possibly server boost level, sources conflict). Third-party 2026 guides, UNCONFIRMED: https://onestream.live/blog/how-to-stream-on-discord-most-easy-steps/ . VP9 and AV1 support conflicts across sources (UNCONFIRMED).
- DAVE doc says Go Live streams are also E2EE. See A4.

### A4. DAVE end-to-end encryption
- Open protocol; whitepaper at https://github.com/discord/dave-protocol and https://daveprotocol.com (v1.1.4 summarized); reference libs https://github.com/discord/libdave (C++ and JS, MIT per page). Discord says E2EE is required for DM/group calls, voice channels (not stage), Go Live; docs say required from 2026-03-01. https://docs.discord.com/developers/topics/voice-connections
- Design: MLS 1.0, ciphersuite DHKEMP256_AES128GCM_SHA256_P256. Voice gateway is the MLS delivery service and "external sender" (only Add/Remove proposals). Credentials are basic: identity = 64-bit user ID. Per-sender key from MLS-Exporter label "Discord Secure Frames v0"; ratchet advances every 2^24 frames; frames encrypted with AES-128-GCM (8-byte truncated tag, ULEB128 nonce) applied after codec encoding (SFrame-like), with codec headers left clear so SFU/packetizer still work (Opus fully encrypted; VP8 first bytes clear; H.264 non-VCL clear; AV1 OBU headers clear and needs patched depacketizer). Frame marker 0xFAFA. Epoch transitions with ops 21-24, passthrough while mixed clients. Verification: ECDSA P-256 identity keys, 45-digit pairwise code, 30-digit epoch code. Known limits: metadata visible, AES-GCM not key-committing, SFU can inject silence. https://daveprotocol.com
- Reuse for Hubbub: feasible but heavy. LiveKit has its own SFrame-style E2EE (listed on the server README, https://github.com/livekit/livekit) so you likely do not need DAVE. For a friend group on your own server, E2EE protects against a hosted/compromised server; if the owner runs the server, transport encryption (DTLS-SRTP) is already enough. DAVE is optional; skip for v1 (my judgement).

### A5. Noise suppression, echo, PTT, VAD
- Krisp runs on-device ML; no audio goes to Krisp servers; auto-disables if CPU cannot keep up; added to mobile too. https://discord.com/blog/tune-into-discord-with-krisp-noise-suppression-on-ios-and-android , https://www.technipages.com/discord-krisp-noise-suppression/ . Krisp is proprietary/commercial.
- Free alternatives: libwebrtc already ships AEC3 echo cancel, AGC, NS (browser getUserMedia constraints echoCancellation/noiseSuppression/autoGainControl); RNNoise (BSD) and DeepFilterNet (MIT/Apache) for ML denoise (UNCONFIRMED here, from memory).
- Voice activity: Discord's protocol sends "Speaking" flags and stops packets in silence (post above). Push-to-talk is client-side (global hotkey is a desktop-only feature; mobile uses a button). Details of Discord's VAD not published in sources I fetched.

### A6. Storage, read states, permissions
- Messages: Cassandra partitioned by (channel_id, bucket ~10 days), clustered by Snowflake message_id (2017, STALE?). https://discord.com/blog/how-discord-stores-billions-of-messages
- 2023: moved to ScyllaDB (72 nodes vs 177 Cassandra), Rust data services with request coalescing and channel-ID consistent-hash routing; p99 reads 15 ms vs 40-125 ms. https://discord.com/blog/how-discord-stores-trillions-of-messages
- Read states: per-user per-channel counters (last read message, mention count) in a dedicated service rewritten Go->Rust over GC latency spikes with its big LRU cache (2020, STALE?). https://discord.com/blog/why-discord-is-switching-from-go-to-rust (via search snippet, full text not read)
- Permissions: bitfield (string-encoded bigint); base = @everyone | OR of roles; ADMINISTRATOR and owner bypass; channel overwrites applied in order @everyone deny/allow, role deny/allow, member deny/allow; implicit rules (no VIEW_CHANNEL means nothing). https://docs.discord.com/developers/topics/permissions
- Snowflake IDs: 64-bit time-sortable (used above). Good for any DB.

### A7. Clients
- 2018 (STALE?): web uses browser WebRTC; desktop/iOS/Android share a custom C++ media engine on libwebrtc (voice post above). Mobile: iOS React Native per a 2018 secondary report (https://gigazine.net/gsc_news/en/20180807-discord-react-native); I did not retrieve Discord's own current statement.
- Desktop is Electron + React: only a user forum post found (weak): https://support.discord.com/hc/pl/community/posts/360049468354 . The native `discord_voice` module name could not be confirmed from any source (UNCONFIRMED). Desktop clients use zstd via a Rust binding, Android zstd-jni, iOS custom bindings (gateway post above), which implies native/Rust modules in each client.

### A8. What matters at 5-50 users vs Discord scale
Copy at friend scale:
- Snowflake IDs; channels/roles/overwrites permission model with bitfields (cheap, well proven); heartbeat + resume with sequence numbers and replay buffer; intents-style event filtering is optional; per-channel read state (last_read_id + mention_count) in a table.
- Voice: a single SFU, relay-only connection through one open UDP port (Discord skips ICE), silence suppression/DTX, speaking indicator events, bandwidth-adaptive encoder and "send only if someone watches" for screen share.
- Single Postgres or SQLite works for messages: index (channel_id, id). Bucketing, ScyllaDB, request coalescing, sharding, etcd, multi-region voice, 2500-guild shards are Discord-scale only. Zstd streaming compression is nice-to-have only.
- Skip at friend scale: DAVE (use LiveKit E2EE if wanted), Krisp (use RNNoise/browser NS), custom C++ SFU, hardware-encoder tuning (use what libwebrtc gives).

## PART B: One codebase on every device

### B1. Media servers
| Server | License | Language | Client SDKs | Screen share | Built-in TURN | Small-group fit |
|---|---|---|---|---|---|---|
| LiveKit | Apache-2.0 | Go (Pion) | Browser, Swift, Android, Flutter, React Native, Rust, Unity, C++, ESP32 (+ Node/Python) | yes, all SDKs | yes, TURN/TLS and UDP 443 | single binary, Redis only for multi-node |
| mediasoup | ISC | C++ worker + Node or Rust | TS and C++ client libs; you write signaling and apps | via browser/native WebRTC (you build it) | not mentioned | a library, not a server; most DIY |
| Jitsi Videobridge | not read; Apache-2.0 per memory (UNCONFIRMED) | JVM (Kotlin/Java, UNCONFIRMED) | Jitsi Meet SDKs; the bridge is one piece of the Jitsi stack | yes in Jitsi Meet | separate coturn | heavy: Jicofo + Prosody + JVB |
| Janus | GPL-3.0 | C (UNCONFIRMED) | JS demos; community SDKs | via VideoRoom plugin | no (use coturn, UNCONFIRMED) | GPL copyleft, plugin config |
| Pion-based DIY | MIT | Go | any WebRTC client | build it yourself | build it | most work |
Sources: LiveKit https://github.com/livekit/livekit and https://docs.livekit.io/home/self-hosting/deployment/ (needs real domain + CA TLS cert, embedded TURN, ports 7880, TCP 7881, UDP 50000-60000, Redis for production; self-signed certs do not work); mediasoup https://github.com/versatica/mediasoup ; Jitsi https://github.com/jitsi/jitsi-videobridge ; Janus https://github.com/meetecho/janus-gateway . Resource numbers for small groups were not found in any source (UNCONFIRMED); LiveKit docs say CPU and bandwidth are the limits.

### B2. Platform x framework matrix (voice / video / screen share)
Legend: Y = documented; P = partial or needs work; N = no; ? = unconfirmed.
| Platform | Flutter + LiveKit Flutter SDK | React Native + LiveKit RN | Tauri v2 (system WebView + livekit-client JS) | Electron (JS SDK) | Native per platform (Swift/Kotlin/...) |
|---|---|---|---|---|---|
| iOS | Y/Y/P (broadcast extension) | Y/Y/P (broadcast ext + CallKeep advised) | ?/?/N likely (WKWebView limits, see below) | n/a | Y/Y/P (ReplayKit extension) |
| Android | Y/Y/P (mediaProjection FGS) | Y/Y/P (FGS managed from 2.4.0) | ? (WebView needs WebChromeClient permission handler) | n/a | Y/Y/Y (MediaProjection) |
| macOS | Y/Y/Y (ScreenSelectDialog) | ? not documented | Y/Y/Y probably (WKWebView, fixed 2024 bug) | Y | Y (Swift SDK, ScreenCaptureKit) |
| Windows | Y/Y/Y | ? not documented | Y (WebView2 = Chromium) | Y | Y (Rust/C++ SDK) |
| Linux | Y/Y/? (no Wayland notes) | ? | N/P: WebKitGTK ships WebRTC off in distro builds | Y (Chromium + PipeWire portal) | Rust/C++ SDK |
| Web | Y/Y/Y | n/a | n/a | n/a | JS SDK |
Sources: LiveKit Flutter https://github.com/livekit/client-sdk-flutter ; flutter_webrtc table (all six platforms incl. screen capture, iOS with footnote) https://github.com/flutter-webrtc/flutter-webrtc ; RN https://github.com/livekit/client-sdk-react-native (only Android/iOS/Expo mentioned) ; Swift https://github.com/livekit/client-sdk-swift (iOS, macOS, tvOS, visionOS) ; Rust SDK platforms Win/mac/Linux/iOS/Android, Apache-2.0 https://github.com/livekit/client-sdk-rust ; Tauri/WebKit https://github.com/tauri-apps/tauri/discussions/8426 and https://bugs.webkit.org/show_bug.cgi?id=274711 (WebRTC disabled in WebKitGTK, still open as of 2026-03 comment) ; WKWebView getDisplayMedia fix https://bugs.webkit.org/show_bug.cgi?id=274896 ; Electron + Wayland https://github.com/element-hq/element-desktop/issues/853 (portal picker works; apps must not add an X11-style picker). Cell contents for Tauri and Compose Multiplatform are inferred from these partial sources (UNCONFIRMED as complete).

Framework notes:
- Flutter: one codebase for all six native targets plus web, LiveKit SDK + flutter_webrtc cover audio/video/screen share on all, extra native work per OS (iOS broadcast extension in Swift, Android FGS). Trade-off: custom UI toolkit; Linux Wayland capture unverified; desktop niceties (global PTT hotkeys, tray) need plugins.
- React Native: strongest on iOS/Android; desktop needs separate react-native-macos/windows forks, and I found no LiveKit RN desktop support (UNCONFIRMED). Web would be a separate React app sharing logic.
- Tauri v2: tiny, web UI reuse, but depends on system WebView: WebKitGTK on Linux has WebRTC off in standard builds; WKWebView on iOS has a history of getUserMedia permission quirks with custom-scheme origins (https://developer.apple.com/forums/thread/134216 ; STALE?); Android WebView requires native permission handler. Tauri-specific v2 mobile WebRTC status UNCONFIRMED. Workaround: use the LiveKit Rust SDK natively instead of the WebView for media.
- Electron: desktop only, bundled Chromium gives reliable WebRTC, screen share, PipeWire on Wayland; mobile still needs a second app. Trade-off: ~100+ MB RAM and no mobile.
- Kotlin/Compose Multiplatform: no single library covers desktop WebRTC; compose-livekit wraps Android+iOS only and its iOS screen share is in-app only; webrtc-kmp covers Android, iOS, JS; desktop via JVM webrtc-java is DIY. https://klibs.io/project/akardas16/compose-livekit , https://klibs.io/project/shepeliev/webrtc-kmp
- Native per platform: best capture/CallKit/background behavior; 4+ codebases.

### B3. Platform requirements
- iOS screen share: Broadcast Upload Extension target (bundle id = app + ".broadcast"), App Group, in-app capture only covers your own app; extension memory is tightly capped (a blog says ~50 MB, UNCONFIRMED). https://docs.livekit.io/transport/media/screenshare/ ; Twilio ReplayKit notes https://www.twilio.com/docs/video/ios-v4-screen-share
- iOS calls/background: set AVAudioSession playAndRecord/voiceChat; with CallKit you must hand audio session activation to CallKit callbacks. https://github.com/livekit/client-sdk-swift . CallKit is for incoming "calls"; for a Discord-style persistent voice channel, background audio mode (UIBackgroundModes audio) is the usual route (UNCONFIRMED from fetched sources). Note: CallKit is restricted in China only; irrelevant here.
- Android: Android 14+ requires declared FGS type mediaProjection and FOREGROUND_SERVICE_MEDIA_PROJECTION permission; consent each projection session; Play Console foreground-service declaration needed. https://developer.android.com/guide/components/fg-service-types ; https://developer.android.com/media/grow/media-projection ; https://support.google.com/googleplay/android-developer/answer/13392821
- macOS: ScreenCaptureKit is the modern capture API; WebRTC has a SCK capturer, Chromium system-audio via getDisplayMedia reported only from Chrome 141 (one tester, UNCONFIRMED); Electron: macOS 14.2+ needs NSAudioCaptureUsageDescription for audio. https://electronjs.org/docs/api/desktop-capturer
- Windows: browsers/WebView2 and native SDKs capture screen; per-app audio capture is limited in browsers (Chrome supports system audio on Windows). https://addpipe.com/getdisplaymedia-demo/
- Linux Wayland: capture only via xdg-desktop-portal + PipeWire with user consent; works in Chromium/Electron; do not build your own source picker. https://github.com/element-hq/element-desktop/issues/853
- Web: getDisplayMedia; tab audio only in Chromium family; Safari supports getDisplayMedia from v13. https://docs.livekit.io/transport/media/screenshare/
- Store policy: Apple Guideline 1.2 for user-generated content expects report, block, filtering and a response commitment; forum rejection letters cite zero-tolerance terms, flagging, blocking, 24 h action (https://developer.apple.com/forums/thread/807358, secondary). Self-hosted apps where users enter a server address (Element, Mattermost, Jellyfin style) are an established category in both stores, but Apple reviewers need a working demo server and demo credentials in the review notes (UNCONFIRMED here, from experience); Mattermost ships store apps that connect to any server. Moderation tools (report/block/mute) belong in v1 for App Store review.

### B4. Push notifications for a self-hosted app
- APNs/FCM only accept pushes signed with the app publisher's credentials, so a store-published app needs a relay run by the publisher. Matrix: homeserver -> Push Gateway (Sygnal) -> APNs/FCM; Sygnal holds the app's secrets so end users cannot run their own. https://etke.cc/help/extras/sygnal/
- Mattermost: TPNS (free, "not for production") and HPNS (paid) relay for the official store apps; custom-built apps must host their own push proxy. https://docs.mattermost.com/administration-guide/configure/push-notification-server-configuration-settings.html
- Pattern for Hubbub: publisher runs one tiny public relay (server sends event id + user push token over HTTPS; relay holds APNs key/FCM credentials and sends a generic or encrypted payload; client fetches content from its own server, like Matrix "event_id_only"). Minimal data to the relay. Cost: you must operate it.
- UnifiedPush (Android, no Google): app registers with a distributor (ntfy etc.), gets an endpoint URL, server POSTs to it; ntfy can be self-hosted. Docs say UnifiedPush does not work on iOS. https://unifiedpush.org/users/faq/ ; https://etke.cc/help/extras/ntfy/ . Public ntfy.sh rate limit ~250/day per publisher (secondary).
- Web: Web Push with VAPID needs no Firebase and can be fully self-hosted (Chrome blog https://developer.chrome.com/blog/web-push-interop-wins). Safari/iOS web push requires installed PWA (UNCONFIRMED).
- Stoat/Revolt push implementation (pushd): could not be confirmed.

## Hardest problems (ranked)
1. iOS: broadcast extension screen share + background voice + push relay (needs publisher-run relay and App Group plumbing).
2. Linux desktop: WebKitGTK has no WebRTC in stock builds, so Tauri on Linux fails unless you use native LiveKit Rust SDK or ship Electron/CEF/Flutter; Wayland capture needs portal flow.
3. Push for a self-hosted store app (relay, privacy, no iOS UnifiedPush).
4. Android 14/15 mediaProjection consent + FGS declaration.
5. App Review: UGC moderation features and demo server.
