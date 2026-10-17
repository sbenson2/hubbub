# Hubbub: open-source / self-hosted Discord-alternative landscape (as of 2026-10-16)

Stars, last push, license and latest release come from the GitHub REST API (api.github.com/repos/<owner>/<repo>, fetched 2026-10-16/17). Other claims cite the page named. "UNCONFIRMED" = not verified in this pass.

## Comparison table

| Project | License | Server stack / DB | Clients (shipped) | Media | Self-host weight | Health |
|---|---|---|---|---|---|---|
| Fluxer | AGPL-3.0 | TypeScript (Hono) API, Erlang gateway, Rust services; Postgres (self-host), Cassandra (hosted), Valkey, NATS, SeaweedFS | Web, desktop Win/mac/Linux, Android (beta), iOS (TestFlight), Flutter mobile client | LiveKit (planned replacement by own system) | 8 GB RAM min, 16 GB for small active community; ~25 containers upstream | 10.6k stars, daily releases (fluxer-api@2026.1017) |
| Stoat (ex-Revolt) | AGPL-3.0 (crates may differ) | Rust microservices; MongoDB, Redis/KeyDB, MinIO, RabbitMQ | Web/PWA, Electron desktop, Android (Kotlin Compose), iOS in development; most official clients do not support self-hosted instances | LiveKit; video + screen share launched Jul 2026 | 2 vCPU/2 GB min, Caddy, ports 80/443, 7881/tcp, 50000-50100/udp | 3.4k stars (server), v0.16.1 on 2026-10-15 |
| Spacebar (ex-Fosscord) | AGPL-3.0 | TypeScript (+C# bits); DB not confirmed | Discord-compatible clients, Fermo, own React client (last push Feb 2026) | WebRTC server in repo, status unconfirmed; earlier FAQ said no voice/video | npm/Docker/Nix | 2.2k stars, no GitHub releases |
| Matrix: Synapse + Element X + Element Call | AGPL-3.0 (Synapse, Element) | Synapse Python + Postgres; Tuwunel Rust (Apache-2.0, RocksDB, UNCONFIRMED) | Element Web/Desktop, Element X iOS (Swift) / Android (Kotlin) | MatrixRTC on LiveKit SFU; E2EE | Synapse + LiveKit + lk-jwt-service + TURN + .well-known | Synapse 4.7k stars, v1.163.0 (Oct 14); Tuwunel 2.6k, v1.9.4; Element Call v0.28.0 |
| Mumble | BSD-3-Clause | C++/Qt server (Murmur), own protocol | Win/Linux/mac desktop; Mumble iOS; Mumla (Android) | Opus over UDP (AES-OCB), TLS control; no screen share | Tiny | 8.3k stars, v1.5.939 (Oct 11, 2026) |
| Jitsi Meet | Apache-2.0 | Jitsi Videobridge (Kotlin SFU), Jicofo, Prosody (XMPP) | Web, iOS/Android apps (UNCONFIRMED detail), Electron | SFU (JVB), TURN via coturn | Ports 80/443, 10000/udp, 5349/tcp TURN; domain required | 30k stars, stable release 2026-09-14 |
| Rocket.Chat | MIT-ish/custom (API says NOASSERTION); Enterprise tier | TypeScript/Meteor, MongoDB (UNCONFIRMED) | Web, desktop, mobile (UNCONFIRMED) | No native voice channels; Jitsi/BBB/Pexip/Meet apps | Heavy | 46k stars, 8.9.0 (Oct 5, 2026) |
| TeamSpeak 6 | Closed source | Closed | Win/mac/Linux, mobile (UNCONFIRMED) | Own; screen share in TS6 beta | Docker server | TS6 beta 6.0.0-beta4.1 (It's FOSS, Aug 2026) |
| Gryt | AGPL-3.0 | Go signalling + Pion SFU; SQLite; S3 | Web, Electron (Linux/mac/Win) | Pion SFU, Opus, simulcast, AV1 SVC, RNNoise | Docker Compose, Helm | 38 stars, early, "expect breaking changes" |

## 1. Per-project findings

### Fluxer (newest and most relevant, 2026)
- AGPL-3.0, ~10.6k stars, 814 forks, GitHub issues closed in favor of feedback.fluxer.com. https://github.com/fluxerapp/fluxer
- Stack: TypeScript/Hono API, Erlang/OTP gateway (WebSockets, sessions, presence), Rust services (media proxy, users, messages, push, unfurl, GIF, snowflake IDs). Cassandra hosted, Postgres for self-hosters, Valkey, NATS, Elasticsearch or Meilisearch. ScyllaDB dropped after license change. https://fluxer.app/blog/how-i-built-fluxer-a-discord-like-chat-app
- Voice/video: LiveKit now, "planned to be replaced by Fluxer's own system" (same blog).
- Clients: web; desktop Windows (installer/portable/ARM64), macOS dmg, Linux (Flatpak, deb, rpm, AppImage); Android Google Play beta + APK from a flutter_client repo; iOS TestFlight. Desktop framework (Electron vs Tauri) UNCONFIRMED. https://github.com/fluxerapp/fluxer
- Self-hosting: Docker, hostname with A record, 80/443 tcp, 443/udp, 7881/tcp, 7882/udp (LiveKit), bundled Postgres, SeaweedFS uploads. Min 2 vCPU/8 GB RAM/20 GB; small active community 4 vCPU/16 GB; 4 GB host needs low-memory overrides. https://docs.fluxer.app/operator/get-started/
- Railway template says upstream is ~25 containers and Railway disables voice because no UDP. https://railway.com/deploy/fluxer-chat
- Monetization: optional "Operator Pass" $199, unlocks nothing in software. Blog above.
- Screen share mobile / Wayland: UNCONFIRMED.

### Stoat (formerly Revolt)
- Renamed Oct 1, 2025 after a trademark cease-and-desist; self-hosted instances needed no change except `docker compose -p revolt down` on upgrade. https://en.wikipedia.org/wiki/Stoat_(software), https://alternativeto.net/news/2025/10/chat-app-revolt-rebrands-to-stoat-keeps-all-services-features-and-core-values-unchanged, https://github.com/stoatchat/self-hosted
- Rust backend crates: delta (REST), bonfire (WebSocket events), autumn (files), january (proxy), gifbox (Tenor replacement), crond, pushd. MongoDB + Redis + RabbitMQ + MinIO. AGPL-3.0. https://github.com/stoatchat/stoatchat
- Clients: web (for-web, 767 stars), Electron desktop, Android (Kotlin/Compose, for-android 236 stars), iOS "in development". https://en.wikipedia.org/wiki/Stoat_(software)
- Voice: LiveKit. Video chat + screen share (with audio) launched on main instance July 17, 2026; code was available to self-hosted instances. https://stoat.chat/release-notes/93eb1f4ec77444ca9fb13617e0e6c0b1 , Wikipedia above. Mobile support for video/screen share: UNCONFIRMED.
- Self-host: Caddy, Mongo, KeyDB, MinIO (moving to "silo"), RabbitMQ, LiveKit; 2 vCPU/2 GB minimum; ports 80/443, 7881/tcp, 50000-50100/udp. https://github.com/stoatchat/self-hosted
- Gotchas documented there: video resolution limit kicks users who exceed config; newer MongoDB needs AVX-capable CPU (pin mongo:4.4); KeyDB fails on some ARM (use valkey); Docker bypasses UFW exposing Mongo; breaking config renames (Nov 2024, Oct 2025, Feb 2026); **most official clients don't support self-hosted instances, only web/PWA**.
- Health: 3.4k stars, v0.16.1 (2026-10-15). Surge in early 2026 strained servers (Wikipedia). Lemmy reports that older self-hosted images lacked voice; conflicting guide claims it works: https://lemmy.amethyst.name/post/1257494/468532 vs https://selfhosting.sh/apps/stoat/

### Spacebar (Fosscord)
- "Free open source reimplementation and extension of Discord's client-server API"; goal is feature parity with discord.com; supports Discord clients but "not every client will connect". https://docs.spacebar.chat/ , https://github.com/spacebarchat/server
- TypeScript, AGPL-3.0, 2.2k stars, 5.9k commits, no GitHub releases listed; client repo last pushed 2026-02-10. Repo contains `src/webrtc`.
- Voice/video: an older FAQ quoted on Lemmy says no voice/video in any instance, "very difficult" because it must match Discord's implementation. Current state UNCONFIRMED. https://lemmy.mariusdavid.fr/post/288207
- Database, hardware, mobile, Wayland: UNCONFIRMED.
- Lesson: cloning Discord's undocumented API means chasing a moving target (inference from the above).

### Matrix (Synapse / Tuwunel / Element X / Element Call)
- Synapse AGPL-3.0 Python, 4.7k stars, v1.163.0; Tuwunel Apache-2.0 Rust successor to conduwuit, 2.6k stars, v1.9.4 (2026-10-10). GitHub API; https://railway.com/deploy/tuwunel
- Element X: iOS Swift, Android Kotlin (2.4k stars). Element Call: AGPL, v0.28.0, group calls on LiveKit SFU, E2EE. https://element.io/blog/end-to-end-encrypted-voice-and-video-for-self-hosted-community-users/
- Element withdrew its free MatrixRTC backend in 2025 ("no longer sustainable"); self-hosters must run their own MatrixRTC/LiveKit (ESS Community or own stack: LiveKit + JWT service + Redis + coturn, advertised via .well-known `org.matrix.msc4143.rtc_foci`). Same blog; https://tomfos.tr/matrix/livekit/
- Reported issues: Element X `MISSING_MATRIX_RTC_TRANSPORT` on self-hosted Synapse+LiveKit https://github.com/element-hq/element-call/issues/3825 ; calls stuck on "Waiting for media" on Continuwuity but fixed on Tuwunel https://forgejo.ellis.link/continuwuation/continuwuity/issues/763 ; "Element Calls are pretty inconsistent" (Apr 2025, Reddit r/elementchat).
- Screen share on mobile Element X: UNCONFIRMED (no source found). Wayland: UNCONFIRMED.
- Synapse pain: Postgres effectively mandatory (SQLite corrupts), storage bloat from large federated rooms, media/history purge burden, federation assumed on. https://yaky.dev/2025-11-30-self-hosting-matrix/ , https://pie.gravitywell.xyz/post/63911

### Mumble
- BSD-3-Clause, C++/Qt, Opus, TLS control + AES-OCB UDP audio, Linux/Windows/macOS/iOS/Android (Mumla). No screen share. https://en.wikipedia.org/wiki/Mumble_(software)
- 8.3k stars, 1.5.939 on 2026-10-11 (GitHub API). Reviewers: powerful but harder to configure, no built-in screen share. https://nordvpn.com/blog/discord-alternatives/ (secondary source)

### Jitsi Meet
- Apache-2.0, 30k stars. Components: Jitsi Videobridge (SFU), Jicofo (conference focus), Prosody (XMPP signalling). https://jitsi.github.io/handbook/docs/architecture/
- Ports: 80/tcp, 443/tcp, 10000/udp; 5349/tcp TURN fallback via coturn; 3478/udp optional STUN; needs a domain with A record. https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-quickstart/
- Meeting-room model (no persistent text/voice channels). E2EE, mobile screen share, Wayland: UNCONFIRMED here.

### Rocket.Chat
- 46k stars, 8.9.0 (2026-10-05); license reported as NOASSERTION by API (open core with Enterprise plan). Video via marketplace apps (Jitsi, BBB, Pexip, Google Meet); some Jitsi features Enterprise-only. https://developer.rocket.chat/docs/video-conferencing-apps.md , https://docs.rocket.chat/docs/jitsi-app
- Third-party claim that group voice/video is behind paid tiers or add-ons (unverified): https://techfuelhq.com/articles/self-hosted-discord-alternatives-2026/

### TeamSpeak (closed source reference)
- TS6 still beta (6.0.0-beta4.1); screen sharing live (reports of 1440p60 and up to 4K); server-side screen sharing on self-hosted servers unclear. https://alternativeto.net/news/2026/8/teamspeak-6-will-finally-introduce-direct-calls-4k-screen-sharing-and-picture-in-picture/ , https://community.teamspeak.com/t/teamspeak-6-0-0-beta1-screen-camera-sharing-communities-design-overhaul/54925?page=4
- A March 2026 forum comment: TS3 screen share does not work on Linux. https://discuss.mschae23.de/comment/40905

### Other
- Gryt: Go + Pion SFU, SQLite, Electron/web, Opus, simulcast/AV1 SVC, RNNoise, Docker Compose in "two files"; 38 stars, early. https://github.com/gryt-chat/gryt
- Nextcloud Talk (spreed): AGPL, 2.2k stars; not Discord-like (UNCONFIRMED features). Mattermost, Zulip: text-first; Mattermost voice/video described as an afterthought (secondary source, nordvpn link above).

## 2. Cross-cutting technical facts
- LiveKit (Apache-2.0, Go, 21.5k stars, v1.13.10 on 2026-10-14) is the SFU behind Stoat, Fluxer and Element Call. Official client SDKs exist: JS, Swift, Android, Flutter (all Apache-2.0, pushed within last week). GitHub API.
- LiveKit iOS screen share: in-app capture by default; full-screen needs a Broadcast Upload Extension with app group; the extension is a separate process (vendor claim of ~50 MB cap, unverified). https://docs.livekit.io/transport/media/screenshare/ , https://www.forasoft.com/blog/article/how-to-implement-screen-sharing-in-ios-1193
- Android capture uses MediaProjection (LiveKit docs snippet, truncated).
- Linux/Wayland: browsers route capture via xdg-desktop-portal + PipeWire. https://access.redhat.com/solutions/6712111 . Tauri/WebKitGTK WebRTC reportedly needed X11 in one user's setup (https://github.com/tauri-apps/tauri/discussions/8426); no confirmation that getDisplayMedia works in WebKitGTK. Electron/Chromium path not verified here, but Gryt, Stoat and Fluxer-desktop all pick Electron-class or web clients (Fluxer desktop framework unconfirmed).
- UDP media ports must be reachable from the internet in every SFU design (Stoat 7881/50000-50100, Fluxer 7881/7882, Jitsi 10000). PaaS hosts without UDP (Railway) cannot run voice.

## 3. Pain points reported
1. Voice is the hard part to self-host: UDP port forwarding, TURN, `.well-known` discovery, LiveKit config (Element, Stoat docs above; NixOS thread https://discourse.nixos.org/t/does-anyone-self-host-a-realistic-matrix-setup-with-audio-video-calls/75251).
2. Free hosted media infrastructure disappears (Element ended its free MatrixRTC backend).
3. Official mobile/desktop clients that cannot point at a self-hosted server (Stoat).
4. Breaking config changes between releases (Stoat upgrade notices).
5. Heavy resource use: Fluxer 8 to 16 GB RAM, 25 containers; Synapse DB bloat; Rocket.Chat.
6. Discord API clones lag and break (Spacebar).
7. Inconsistent calls on mobile (Element Call), interop bugs across homeservers.
8. No single product covers text + voice + video + screen share well: summary in https://discuss.mschae23.de/comment/40905 and https://nordvpn.com/blog/discord-alternatives/ (secondary).
9. Security footguns: Docker publishing DB ports past UFW (Stoat docs).
10. Project rename/trademark risk (Revolt to Stoat).

## 4. "Hubbub" name conflicts
- Hubbub GmbH (Vienna), voice social network "bubs", hubbub.fm, iPhone + web (2011-era, status unknown): https://www.alexanderjarvis.com/hubbub-pitch-deck-raise-seed-capital-investment/ , https://www.iculture.nl/apps/hubbub-het-gesproken-broertje-van-twitter/
- Hubbub FriendFeed desktop client (2008): https://techcrunch.com/2008/11/26/hubbub-launches-friendfeed-desktop-app
- Hubbub, local-moms playgroup community app (Product Hunt): https://hunted.space/product/hubbub
- Research prototype "Hubbub" mobile IM (ACM): https://cacm.acm.org/?p=4694
- GitHub repos named hubbub (all tiny, no trademark weight): PubNubDevelopers/angularjs-hubbub (82 stars, 2018, "chat application"), PhishyFish/hubbub (Discord-inspired, 9 stars, 2018), hubbub-community/hubbub-chat-server (1 star, 2023), XilefEel/hubbub ("a Discord-inspired chat platform", 0 stars, pushed 2026-10-15), thanghn14/hubbub-chat (2026), g105b/hubbub (Hack24 2016). GitHub search API, 2026-10-16.
- Other: "Hubbub Suppression for Voice" (masyagin1998/HSV), an unrelated audio-research repo.
- No major current Discord-alternative named Hubbub found. UNCONFIRMED: trademark registrations (USPTO/EUIPO not searched), app-store listings, domain availability (hubbub.chat, .app, .gg unresolved).
