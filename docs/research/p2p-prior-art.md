# Hubbub P2P prior art (researched 2026-10-16)

Method: web search plus a few page fetches. Search summaries were not all verified against the primary page. Items marked UNCONFIRMED had no source found. Items marked (design inference) are my reasoning, not a sourced claim. Items older than 2024 are flagged STALE?.

## 1. Existing apps

### Keet / Pear (Holepunch)
- Calls are described as fully P2P, group and direct. https://support.keet.io/rooms/dms-and-calls
- Desktop supports several simultaneous screen shares; Keet advises not sharing screen and camera together because of load. https://support.keet.io/voice-and-video-calls/video-calls-and-share-screen
- Participant limit: UNCONFIRMED (none published). Mesh vs relay topology for calls: UNCONFIRMED. keet.io says "optimized for large group calls" with no number. https://keet.io/
- Quality evidence is anecdotal and mixed: one 2023 review says no lag, others report freezing and weekly updates (STALE?). https://justuseapp.com/en/app/6443880549/keet-by-holepunch/reviews . Nothing found on 1080p60.
- NAT traversal: HyperDHT does peer discovery and hole punching; Holepunch contrasts this with WebRTC's central server. Search summary quoting Holepunch engineers; primary page not fetched. Failure rate and relay fallback: UNCONFIRMED.
- Rooms use Autobase (multi-writer Hypercore linearized into one view; reorders and re-applies the view when new causal info arrives; writers are added by an existing writer). https://docs.pears.com/building-blocks/autobase
- Writer removal and banning in Autobase: UNCONFIRMED (not found in docs searched).
- Blind peers: always-on servers that store and forward encrypted cores/Autobases without the read key, so data survives when no writer is online. https://docs.pears.com/how-to/blind-peering/ . Note this is an optional always-on helper, not pure P2P.
- Open source: Pear Runtime was open-sourced Feb 2024 (~100 repos). https://pears.com/news/holepunch-unveils-groundbreaking-open-source-peer-to-peer-app-development-platform-pear-runtime/ . Keet app itself: UNCONFIRMED (likely closed; no license found). Keet runs on the runtime including mobile, listed on App Store and Google Play (source: gitnation listing, weak) https://gitnation.com/contents/pear-runtime-zero-infrastructure-high-scale-applications . The stack (Hypercore, HyperDHT, Autobase) is the reusable part, in JS (Bare runtime).

### Jami
- Swarm conference design: a "Rendezvous" device mixes all incoming calls. Caller hosts by default; an admin can set a default host device; host must accept the role. https://docs.jami.net/developer/jami-concepts/calls-in-swarm.html
- Host migration: not described in that doc. Host crash is handled by persisting hosted calls and fixing up the conversation on restart. https://git.jami.net/savoirfairelinux/jami-daemon/-/commit/89609362217aa31b2c859c609daeb6c1ff7e5cfe
- So Jami = elected-mixer topology with a fixed host, not an SFU with migration. This is the closest shipped analog to "one peer is the SFU".
- Complaint: host upload is strained (e.g. file sending during a conference); request for per-user limits. https://git.jami.net/savoirfairelinux/jami-project/-/issues/1436
- Early swarm groups were small (about 8). https://jami.net/vil/ (weak)
- TURN setup and a user-complaint survey: UNCONFIRMED (searches did not surface them).
- iOS notifications: app sends empty push notifications to wake the app, which then fetches messages; a 2022 post says push partly relies on central servers (STALE?). https://forum.jami.net/t/how-do-ios-app-notifications-work/602

### Quiet, Briar, Berty, Session, Cabal, SSB (brief)
- Quiet: Tor + libp2p/IPFS + OrbitDB (CRDT), one isolated network per community; README says unaudited; 2022 post says mobile not ready (STALE?). https://lists.torproject.org/pipermail/tor-dev/2022-April/014723.html . Text only, no media calls.
- Briar: must run in background; iOS only allows roughly a 15-minute wake; team is building an encrypted "mailbox" store-and-forward device; push would leak metadata to Apple/gateway. https://code.briarproject.org/briar/briar/-/wikis/FAQ
- Berty/Wesh: IPFS + libp2p, async messaging, Signal-inspired key rotation; protocol page says not fully audited (2021, STALE?). https://berty.tech/protocol
- Session: not P2P; uses service-node swarms for offline storage. https://arxiv.org/pdf/2002.04609 (STALE? 2020). Closed-group removal and key rotation: UNCONFIRMED.
- SSB: pubs store messages for offline peers; clients can need significant storage and bandwidth. https://arxiv.org/pdf/2402.03239 . Cabal: UNCONFIRMED, nothing found.
- Lesson: none of these ships HD group video. The real-time media prior art is only Keet (unverified details) and Jami.

## 2. NAT traversal evidence
- libp2p DCUtR (IMC'26, 4.4M attempts, 85k networks): about 70% +/-7.1% hole-punch success, conditional on relay reservation and public-address discovery. About 29% of attempts failed before punching, so end-to-end is lower. TCP and QUIC are about equal. 97.6% of successes come on the first attempt. Volunteer-client bias may inflate numbers. Port mappings (UPnP/PMP) help. https://arxiv.org/html/2510.27500v1 , https://probelab.io/publications/large-scale-measurement-of-nat-traversal-for-the-decentralized-web-a-case-study-of-dcutr-in-ipfs/
- Iroh: docs give an anecdotal ~90% direct rate; formal production measurement not published; failures fall back to relay, traffic E2E encrypted. https://docs.iroh.computer/about/faq (via search summary). Relay is open source (`iroh-relay` binary, public IP + DNS name + ACME TLS), self-hostable, interoperates with other relays; docs recommend at least two. https://docs.iroh.computer/add-a-relay . Public n0 relays are rate-limited. Self-hosted success data: none.
- Tailscale (2020, STALE?): STUN plus simultaneous send works "over 90%" (estimate). Hard NAT on one side is solvable by birthday-paradox probing (1024 probes about 98%). Two hard NATs are near hopeless (about 0.01% in 20 s). UPnP/NAT-PMP/PCP help but fail on CGNAT. DERP relays are the fallback and also the coordination channel. https://tailscale.com/blog/how-nat-traversal-works
- Takeaway: plan for roughly 10-30% of pairs needing a relay; mobile carriers (CGNAT) and double NAT are the worst case. Every serious system keeps relays.

## 3. Group media without a server
- Mesh: each peer uploads N-1 copies. Vendor blogs put the practical limit near 4 participants on consumer links; the source figures vary and are vendor material. https://antmedia.io/webrtc-network-topology/ , https://www.forasoft.com/learn/video-streaming/articles-streaming/sfu-mcu-mesh-topologies
- 1080p60 bitrate: Twitch H.264 about 6 Mbps; YouTube 4.5-9 Mbps, up to 12 for fast motion; AV1 roughly 40-45% less than H.264 for similar quality (rule of thumb); keep 20-35% upload headroom. https://compresto.app/blog/best-bitrate-for-twitch , https://livepush.io/tools/bitrate-calculator/ . Those are streaming-ingest numbers; real-time WebRTC with low latency usually needs more bitrate for equal quality (design inference).
- Arithmetic (design inference): at 6 Mbps per viewer, 1 sharer uploading to 4 viewers = 24 Mbps; to 9 viewers = 54 Mbps (mesh) -- too much for most home uplinks. With 8 Mbps AV1/H.264 hardware encode, same issue.
- Elected SFU / peer forwarding: I found NO shipped serverless design with host migration (search found only hybrid P2P-to-SFU upgrades; Jitsi P2P4121 and AppRTC 2026 write-up, both with a server SFU). https://bloggeek.me/webrtcglossary/p2p4121 , https://webrtc.rs/blog/2026/07/22/apprtc-p2p-to-sfu-upgrade . Embedding LiveKit/Pion/mediasoup as the elected node: UNCONFIRMED as prior art; it is technically plausible since Pion is a Go library (design inference).
- Segment-based P2P (WebTorrent, PeerTube) latency comparison: UNCONFIRMED, not researched; general knowledge is that segment/HLS-style is multi-second latency, unsuitable for interactive screen share (design inference).
- Simulcast/SVC and viewer-forwarding (relay tree) is the standard way to cut sharer upload (general WebRTC practice; no source fetched).

## 4. Permissions and moderation
- MLS (RFC 9420): asynchronous group key agreement, forward secrecy and post-compromise security, 2 to thousands of members; a Remove commit rotates keys so the removed member cannot read new messages. https://www.rfc-editor.org/rfc/rfc9420 , https://cryspen.com/post/mls-introduction/ . PCS needs members to stay active; inactive members may be removed. Removed members keep whatever they already decrypted (inherent; design inference).
- Matrix: state resolution merges conflicting room state; higher power level wins; State Res v2.1 (MSC4297, Aug 2025) fixed a state-reset flaw (CVE-2025-49090); room v12 adds explicit creator privilege. https://www2.matrix.org/blog/2025/08/project-hydra-improving-state-res . Megolm rotation on removal: UNCONFIRMED here. Old docs are STALE? https://matrix.org/docs/older/moderation/
- Ink & Switch Keyhive/Beehive/Beelay: capability-based write control, BeeKEM group key agreement (TreeKEM-like, my inference), Beelay syncs the membership graph first so peers know what the other may access; still a research project. https://www.inkandswitch.com/keyhive/notebook/ , https://inkandswitch.com/beehive/notebook
- Concurrent admin conflicts (admin A bans B while B promotes C): the hard case; Matrix state res and Keyhive revocation-wins rules are the studied answers. Hubbub-specific rule is a design choice (design inference).

## 5. History sync
- Autobase and OrbitDB are multi-writer logs/CRDTs. Offline-to-offline delivery needs an always-on third party: Keet blind peers, SSB pubs, Briar mailbox, Session swarms. https://docs.pears.com/how-to/blind-peering/ , https://arxiv.org/pdf/2402.03239 , https://code.briarproject.org/briar/briar/-/wikis/FAQ
- Pure "any member online" store-and-forward works only if members overlap; otherwise a seed box is needed. Storage growth numbers: UNCONFIRMED; mitigation is retention windows plus snapshotting (design inference).

## 6. Phones as peers
- iOS: Briar says wake about every 15 min at best; persistent listening is impossible. https://code.briarproject.org/briar/briar/-/wikis/FAQ . Jami uses empty push to wake. https://forum.jami.net/t/how-do-ios-app-notifications-work/602
- Android background limits and FCM requirement: not researched; Briar runs a foreground service (general knowledge, UNCONFIRMED here).
- Conclusion: phone cannot usefully seed on iOS; treat phones as clients that sync from a PC peer on launch. Pushing requires APNs/FCM, which means some always-on relay holding device tokens (inference); a PC peer can send "empty" pushes only through a push gateway someone runs.

## 7. P2P-specific risks (partly inference)
- IP exposure to members (accepted by owner); IP exposure via invite leaks or ex-members who keep the group key/address.
- Sybil/spam: mitigated by friend-only invites; members' keys are the identity.
- Malicious elected SFU/relay peer can drop or see metadata but not E2E contents if media is SRTP/E2EE (design inference).
- Unaudited stacks: Quiet and Berty explicitly say so. Keet/Pear audit status UNCONFIRMED.
- DoS of a host peer's uplink (Jami issue 1436).
- Key compromise of an admin with no central revocation: needs a recovery quorum (design inference).
