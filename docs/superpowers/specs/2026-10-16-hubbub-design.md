# Hubbub — Design

Date: 2026-10-16
Status: draft for owner review

Research behind this document lives in `docs/research/`:
- `open-source-landscape.md`: existing self-hosted Discord alternatives, self-hoster pain points, name check
- `discord-internals-and-stack.md`: how Discord works, media servers, cross-platform frameworks, platform constraints
- `p2p-prior-art.md`: peer-to-peer chat and calls (Keet, Jami, Iroh, MLS, NAT traversal numbers)

Each decision below is tagged **[owner]** if the owner decided it, or **[call]** if it is the designer's call. The owner can overturn any **[call]**.

---

## 1. Intent

Hubbub is a free, open-source hangout app for a group of friends while they play games together. At its heart are **voice chat and text channels ("lobbies")** like Discord's, on every device, with no ads, no upsells and no company in the middle. **[owner]**

The defining moment **[owner]** is game night. Friends are playing on their PCs, hanging out in a voice channel with the text channels alongside, some with cameras on. Anyone who wants to share their screen can do it free, at full 1080p 60 fps, and the others tune in. Friends who are away from their desks keep up on their phones.

**Priorities [owner, 2026-10-17]:**
- Voice chat and text lobbies are the product. They must feel instant and never break.
- Screen sharing is the standout extra. It's optional, free and full quality, whereas Discord puts 1080p60 behind its paid tier.
- When trade-offs collide, voice and text win.

### Why it exists
Discord does this well, but it is a company product with ads, upsells and central control. Today's open-source alternatives each miss part of it (see `docs/research/open-source-landscape.md`):
- Matrix/Element is secure but hard to host.
- Fluxer and Stoat work like Discord, but they are heavy to host and voice breaks easily.
- Jami is peer-to-peer and free, but rough, and it doesn't work like Discord.
- Mumble and TeamSpeak are strong on voice only.

None of them does text, voice, video and screen share well, across all devices, with easy hosting and end-to-end encryption.

### What makes it different
1. **No servers to set up.** Each community is kept alive by its members' apps (§4). **[owner]**
2. **Extremely secure.** Everything is end-to-end encrypted, keys stay on devices, and no company servers hold user data. **[owner]**
3. **Free to run.** Nobody has to rent anything. **[owner]**
4. **Easy.** Install, accept an invite, and be talking within two minutes, with no router settings. **[owner: easy; call: the two-minute bar]**

---

## 2. Goals, non-goals, anti-goals

### Goals (v1)
- Discord-style communities ("servers" in the UI) with text channels and voice channels. **[owner]**
- Text chat with images, files, links, @mentions, replies, reactions and editing/deleting. **[owner-approved playback]**
- Voice in voice channels, with an optional camera. **[owner]**
- Optional, free screen sharing from desktop at up to 1080p 60 fps. Anyone in the channel can tune in. **[owner]**
- A friends list and direct messages (1:1 and small groups), including calls. **[owner-approved playback]**
- One account across every community, held on the user's own devices. **[owner]**
- Runs on Windows, macOS, Linux, iPhone, iPad and Android. **[owner: all devices, mostly PC]**

### Non-goals (v1)
- **Sharing your screen from a phone.** Phones can watch but not share, because phone screen sharing is the hardest platform work. **[owner-approved playback]**
- **A public server list or discovery.** Communities are friend-only and joined by invite. **[owner, 2026-10-16: "friend only servers… we can drop this"]**
- **A browser version.** A web client can't host, and it would need a real domain and TLS certificate per community, which breaks "easy". **[call]**
- **Threads, forum channels, pins, custom emoji, stickers and in-game overlay.** These can come later. **[call]**
- **Seeing chat history from before you joined a community or linked a device.** This works like Signal, not Discord. **[owner, 2026-10-17]**
- **Big communities with many people online at once.** v1 is built for about 5 people online, rarely more (§4.3). **[owner, 2026-10-17]**
- **Phones working with no PC online.** Phones never connect straight to each other, so a community or DM needs a PC online. **[owner, 2026-10-17]**

### Anti-goals (a failure even if it technically works)
- **Ads, paid tiers or perks like Nitro, bots/app store, sticker shops.** **[owner]**
- **Anything that depends on a company staying up.** If the Hubbub project's own small services disappear, communities must keep chatting and calling (§4.7). Element shutting down a free backend in 2025 broke self-hosters; Hubbub must not repeat that. **[owner: nobody owns it]**
- **Exposing users.** Strangers must never learn a member's IP address, read their messages, or reach their machine. **[owner]**
- **Self-hosting pain.** No port forwarding instructions, Docker, domains or config files for normal users. The research names this as the number-one failure of existing projects. **[owner: anyone can host]**

---

## 3. Product

### 3.1 Accounts **[owner: one account, held on devices]**
- **Sign-up** is picking a display name and an avatar. The app silently creates an identity keypair. No email, phone number or password.
- **Names aren't globally unique.** Each account shows a short tag derived from its key, e.g. `Ace#4F2A`. **[call: tag format]**
- **Linking devices.** You add a device by scanning a QR code shown on an already-signed-in device. Your devices sync your account: profile, friends list, community memberships and settings. Messages sent before a device was linked are **not** copied to it. **[owner: like Signal]**
- **Recovery.** The app shows a recovery code once and keeps reminding the user until they confirm they've saved it. Losing every device and the code means losing the account. There is no "forgot password". **[owner accepted this trade-off]**
- **Restoring from the code** gives back the identity and no past messages. **[owner: like Signal]** Other members still recognise the identity key, so they re-admit the restored device to its communities and friendships. **[call]**

### 3.2 Communities ("servers")
- **Creating one.** Anyone can create a community, and the creator becomes its owner.
- **Joining** is by invite link only. Links can expire, have a use limit, and be revoked. **[call: expiry and use limits]** New members see messages from the moment they join, not before. **[owner: like Signal]**
- **Channels.** There are text channels and voice channels, organised into categories.
- **Roles and permissions** follow Discord's model:
  - Roles carry permission bits, and channels can override them in a fixed order: everyone, then role, then member, with deny applied before allow.
  - The owner and admins can kick, ban, and manage channels, roles and invites.
  - **[call]**: copy Discord's model, as summarised in `discord-internals-and-stack.md`.
- **Unread state.** Each person sees unread and mention badges per channel, like Discord's read states.

### 3.3 Text chat
- **Messages:** markdown-style formatting, emoji, @mentions (user, role, @everyone), replies, reactions, edit and delete, and a typing indicator.
- **Attachments:** images and files, with a 50 MB per-file default that the community owner can change. **[call]**
- **Link previews** are generated on the sender's device and sent with the message. Recipients never fetch the URL, so their IPs never leak to the linked site. **[call, for security]**
- **Search** runs locally over the history on the device. **[call]**

### 3.4 Voice, video, screen share **[owner]**
- **Voice channels are always-open lobbies.** You click in to start talking and click out to leave. Nobody "calls" anyone.
- **Controls:**
  - mute, deafen, and per-user volume
  - push-to-talk or voice activity detection
  - speaking indicators
  - noise suppression and echo cancellation, using the free libwebrtc/RNNoise-class options rather than Krisp, which is proprietary **[call]**
- **Camera** is optional in any voice channel or DM call.
- **Screen sharing:**
  - Desktop only.
  - A user can share a whole screen or one window, including that app's audio where the OS allows it (Windows, macOS through ScreenCaptureKit, Linux through PipeWire). **[call: app audio]**
  - The target is 1080p 60 fps, and viewers fall back to 720p or 360p automatically when bandwidth is short.
  - Video is only sent to people who actually clicked to watch.
- **DM calls** offer the same voice, video and screen share between friends.

### 3.5 Friends and DMs
- **Who you can friend and DM:** anyone you share a community with. **[call; owner approved friends + DMs, not this rule]**
- **How DMs are built:** a DM or group DM is a tiny private community of its participants, using the same machinery as §4. **[call]**
  - **Who hosts a DM.** Any participant's online desktop can host it.
  - **When no participant's desktop is online:** the host of a community the participants share carries the DM, and any DM call, as a blind host. It holds and forwards ciphertext only. **[call]**
  - **When no suitable PC is online at all:** the DM is offline and the app says so plainly. Two phones never connect to each other directly. **[owner: a PC must be on]**

### 3.6 Notifications
- **Desktop** uses native notifications.
- **Phones** get push notifications through the Hubbub push relay (§4.7), which only ever carries an encrypted "something new" ping. The phone wakes, connects to its community, and fetches the actual content.
- Users can mute per channel, per community or per DM.

### 3.7 Moderation and safety
- **Moderator tools:** block a user, report a message to the community's admins, and the admin kick/ban powers above.
- App Store guideline 1.2 expects report, block and filtering tools, so these tools are required before shipping to the stores (`discord-internals-and-stack.md`).

---

## 4. How it works

### 4.1 The rotating host **[owner: "everyone's app is like a server"; owner approved the rotating-host design]**
A community has no permanent server. Any member's **desktop** app can act as its host.

- **Election.** While any desktop member is online, one of them is the host. The host is elected by:
  1. reachability: whether it can accept incoming connections
  2. connection quality to the other members (latency and stability), because voice comes first
  3. upload bandwidth, which matters most when someone shares their screen
  4. uptime

  **[call: criteria and their order]**
- **Hand-over.** When the host leaves, another online desktop member takes over within seconds, like host migration in a game lobby. The target is a call resuming within 5 seconds. **[call: number]**
- **Who never hosts.** Phones connect to the host but never host themselves, because iOS and Android won't keep them running in the background.
- **When everyone is gone.** If no desktop member is online, the community is offline. Phones show a clear "offline" state and queue outgoing messages. **[owner: "if no one is on, the server isn't online"]**
- **Always-on hosts.** Leaving the app open on an always-on machine such as a gaming PC, Mac mini or old laptop makes that machine a near-permanent host. This is optional and free.
- **Blind hosts.** The host role must work on **ciphertext only** (§5). This also lets an optional "blind host" run on a machine that isn't a member, such as a rented server, without being able to read anything. **[call]**
- **What the host does.**
  - It orders and relays new messages.
  - It serves history to members who are catching up.
  - It runs the media forwarder for calls (§4.3).
  - It checks signatures on admin actions.

  The host is a coordinator, not the owner of the data.
- **Members don't blindly trust the host.** A member's desktop can be compromised, so the design defends against a misbehaving host. **[call, for "extremely secure"]**
  - Ordering is signed and hash-chained, and members cross-check it, so a host that drops, reorders or forks history gets caught.
  - Election inputs (reachability, upload, uptime) are measured by other members, not self-reported.
  - Members can evict a host caught misbehaving and re-elect without it. A banned member can never host.

### 4.2 History and sync
- **No history from before you were added.** Under MLS, a new member or newly linked device can't decrypt anything sent before it was added. This is intended. **[owner: like Signal]**
- **Who keeps history.** **[call]**
  - Every device decrypts messages as they arrive and keeps them in its encrypted local database.
  - Desktop members also keep the community's encrypted event log, so members who were offline can catch up. Those members still hold the keys for the period they were members, as long as they process the MLS commits in order.
  - Phones keep all the text they've received.
  - Attachments are encrypted with a per-file key carried inside the message. They're stored on desktops and fetched on demand.
- **History format.** History is an append-only log of signed, encrypted events. While a host exists, it assigns the order. Edits made offline merge when the member reconnects. **[call: append-only signed log, as in Keet/Autobase and Matrix]**
- **Membership and permissions** live in a separate signed admin log. Admin actions are signed events. Conflicting concurrent admin actions are resolved by power level, and the creator holds the highest power, Matrix-style.
  - The builder should study the 2025 Matrix state-resolution fixes (`p2p-prior-art.md`) before designing this.
- **Catching up.** A member who comes online catches up from the current host.

### 4.3 Calls and screen sharing
- **Topology.** The host runs a selective forwarding unit (SFU). Each sender sends one stream to the host, and the host copies it to each viewer. Mesh is rejected because the sharer's upload doesn't scale. Research puts the mesh limit at about 4 participants.
- **Simulcast.** Senders encode several layers, e.g. 1080p60, 720p30 and 360p, and each viewer gets the best layer their connection allows.
- **Encoding.** Use hardware encoding: AV1 where supported, otherwise H.264. **[call]**
- **Encryption.** Media frames are end-to-end encrypted (SFrame-style insertable streams), so the host forwards them without being able to decrypt. Keys come from the community's group key (§5).
- **Bandwidth.** 1080p60 costs about 6 Mbps per viewer of host upload, so 4 viewers need about 30 Mbps. This is why upload speed is an election criterion. Hubbub must tell the sharer honestly when viewers are being downgraded. This limit is physical and accepted. **[owner was told]**
- **Size target.** About 5 people, rarely more. **[owner, 2026-10-17]**
  - **The reference game night** is 5 people in one voice channel, with one 1080p60 screen share watched by the other 4 and up to 3 cameras at 540p30. **[call: the camera numbers]**
  - That needs roughly 40 Mbps of host upload. Below that, cameras step down first and the screen share last. Voice never gives up quality to make room for video. **[owner: voice comes first]**
  - One host per community carries all of its calls, including a second busy voice channel. Spreading media across several PCs is out of scope for v1.
- **Media stack.** **[call: start with LiveKit, keep it behind an interface]**
  - Desktop hosts bundle the LiveKit server (Go, Apache-2.0), and all clients use the LiveKit client SDKs. LiveKit has SDKs for every target platform, plus simulcast, E2EE and screen share.
  - Fluxer, Stoat and Element Call all use it.
  - Known friction:
    - LiveKit normally expects a real domain and a CA-signed TLS certificate, and assumes a fixed server.
    - Running it inside a rotating, peer-to-peer topology is unproven.
  - The first spike (§8) decides between tunnelling LiveKit over the peer connection and building a small Pion- or str0m-based forwarder.

### 4.4 Connectivity
- **Peer connections** use Iroh (Rust, MIT/Apache), which provides QUIC connections with hole punching and relay fallback. **[call]**
- **Only the host has to be reachable.** Every other member connects out to the host. The community therefore needs only one reachable desktop member online, which avoids most NAT failures. Research puts hole punching at about 70–90% success, with 10–30% of pairs needing a relay.
- **How the host becomes reachable:**
  1. automatic router port mapping (UPnP / NAT-PMP / PCP)
  2. hole punching
  3. a relay

  **[call: order]**
- **Relays.** A relay only ever sees encrypted traffic.
  - The Hubbub project runs a small fallback relay.
  - Any community can run its own relay and point at it instead.
  - Video through the project relay may be capped, e.g. to 720p, to control cost. **[call]**
- **Privacy mode.** An optional setting routes a user's traffic through a relay at all times, so other members don't see their IP. **[call]**

### 4.5 Invites and finding the host
- **Invite links are normal https links** on a domain the project owns, so they're clickable in any chat app and work for someone who hasn't installed Hubbub yet. **[call]**
  - The page opens the app if it's installed, and shows download buttons if not.
  - The join secret sits after the `#`, which browsers never send to the web server.
  - The page is static and runs on the same small box as the relays (§4.7).
- **What a link carries:** the community ID, enough information to find the current host, and a one-time join secret.
- **Finding the host** when home IP addresses change, tried in this order **[call]**:
  1. Each member's app remembers other members' last-known addresses and tries them.
  2. The project relay doubles as a lookup point.
  3. Records on the public BitTorrent DHT, stored under a key derived from the community secret and encrypted, so only members can find and read them.

  Hubbub runs its own Iroh relay and discovery and does not depend on n0's public infrastructure.
- **What it can't do:** the link alone doesn't grant decryption keys. Keys are delivered through MLS once an online member or the host's admin-signed invite policy admits the joiner.
  - **[call; builder to finalise]**: the exact mechanism.

### 4.6 Offline and DMs
- **Nobody online:** the community is offline, and outgoing messages wait on the sender's device.
- **Offline DMs:** see §3.5. Every peer-to-peer system studied ends up needing an always-on helper for "never online at the same time". Hubbub's helpers are the optional always-on host and the hosts of shared communities.

### 4.7 The only project-run pieces
The Hubbub project (initially the owner) runs exactly three small pieces. All are open source and self-hostable. All carry only encrypted or opaque data, and all are optional for chatting and calling.
1. **Push relay.** Apple and Google only deliver push notifications to the app's publisher's credentials, so a relay holding those credentials is unavoidable for store-published mobile apps. Matrix's Sygnal and Mattermost's push proxy follow the same pattern. It forwards encrypted pings, never content.
2. **Fallback relay and lookup point.** See §4.4 and §4.5.
3. **Invite page.** A static page for invite links (§4.5). If it's down, existing members are unaffected, and new invites fall back to a code pasted into the app.

If all three disappear, desktop communities keep fully working. Phones lose background notifications and, rarely, connectivity for members behind unreachable networks.

---

## 5. Security requirements **[owner: "extremely secure", "users aren't exposed"]**

### Protects against
- **Strangers and network snoops:** they see nothing, because every connection is encrypted.
- **Relay and push-relay operators, and blind hosts:** they see only ciphertext and metadata such as timing and size.
- **Non-members:** they can't join without an invite and can't read anything without keys.
- **Removed or banned members:** they lose access to everything after their removal.

### Does not protect against (stated plainly in the app's docs)
- A member seeing what is shared with them, and keeping it.
- A removed member keeping history they already had.
- A compromised device.

### Requirements
1. **End-to-end encryption for everything:** messages, files, reactions, profile data inside a community, voice, video and screen shares.
   - Group keys use MLS (RFC 9420) via OpenMLS.
   - Keys rotate on every member removal.
   - Media keys derive from the MLS epoch, the same idea as Discord's DAVE.
   - **[call]**
2. **Keys never leave devices,** except during device linking, which goes over an encrypted, QR-verified channel.
3. **Signed everything:** messages, admin actions and invites are signed by the author's identity key.
4. **Memory-safe code** in every networking, parsing and crypto path Hubbub writes: Rust in the core and Go in the LiveKit server. Unsafe code is avoided, and any that remains must be justified. Widely used, heavily audited C/C++ components are accepted exceptions and must be kept up to date: libwebrtc inside the LiveKit SDKs, the Flutter engine, and SQLite/SQLCipher. **[call]**
5. **Minimal attack surface.**
   - Only a hosting desktop listens for incoming connections, on one port.
   - There is no admin web panel and no local HTTP server exposed to the network.
6. **Abuse limits:** rate limits on joins, messages and uploads, enforced by the host and checked by clients.
7. **Signed, automatic updates,** with security fixes applied by default.
8. **No telemetry, ads or tracking.**
9. **Encrypted local storage** (SQLCipher or the platform keystore). **[call]**
10. **Independent security audit** of crypto and networking before 1.0. **[call]**

---

## 6. Platforms and stack **[owner handed these to the designer; all are calls]**

| Platform | Role | Notes |
|---|---|---|
| Windows | client + host | top priority (most players are on PCs) |
| macOS | client + host | ScreenCaptureKit for capture |
| Linux | client + host | Wayland capture via xdg-desktop-portal + PipeWire, with the system picker only |
| iPhone / iPad | client only | watch screen shares; CallKit and background audio for voice; APNs via push relay |
| Android | client only | watch screen shares; foreground service for voice; FCM via push relay |

- **Core in Rust,** shared on every platform: identity, crypto (OpenMLS), sync, storage, networking (Iroh), and the host role.
- **UI in Flutter,** one codebase for all five platforms, bridged to Rust with flutter_rust_bridge. Research ranked Flutter plus the LiveKit Flutter SDK the strongest single-codebase option for media on every platform.
  - Electron plus React Native was rejected: two UI codebases and heavy RAM use.
  - Tauri was rejected: WebRTC is missing from Linux WebKitGTK, and its mobile WebRTC is unproven.
- **Media:** LiveKit, as in §4.3.
- **Storage:** SQLite on each device, encrypted.
- **License:** MIT, fully open source. **[owner, 2026-10-17]** GPL-family licenses conflict with App Store distribution; MIT is compatible with the Apache-2.0 and MIT dependencies (LiveKit, Iroh, OpenMLS).
- **Distribution:** signed desktop installers from GitHub Releases (with auto-update), the App Store and Google Play. Store releases need the owner's developer accounts.

---

## 7. Success criteria
1. **Easy start.** A friend who has never heard of Hubbub installs it, opens an invite link, and is talking in voice within 2 minutes, with no router changes.
2. **Voice feels instant.** With a host online, clicking a voice channel connects within 1 second. Mouth-to-ear latency between members on the same continent stays under 150 ms. Noise suppression keeps game audio and keyboards out of the mic. **[call: numbers]**
3. **Text is instant and never lost.** Messages appear for online members within half a second. Nothing sent is ever lost, including across host hand-overs and members going offline. **[call: numbers]**
4. **Screen share quality.** On the reference game night (§4.3), with a host that has at least 40 Mbps of upload, the screen share reaches all 4 viewers at 1080p60 with under 300 ms glass-to-glass latency, and the cameras stay at 540p30. **[call: numbers]**
5. **Host hand-over.** If the host quits mid-call, the call and chat resume on a new host within 5 seconds, and no messages are lost.
6. **Consistent history.** After members reconnect, every member's history is identical.
7. **Nothing readable outside members.** Packet captures at relays, the push relay and blind hosts contain no plaintext content.
8. **Survives the project disappearing.** With the project's push relay and fallback relay switched off, desktop communities still chat and call normally.

---

## 8. Biggest risks and the spikes to run first
Ranked by the research.

1. **Calls through a rotating, peer-to-peer host are unproven.** No shipped serverless app documents a host hand-over mid-call, or 1080p60 screen sharing (Keet and Jami don't). *Spike:*
   - the owner's Windows desktop, Mac mini and ThinkPad, one acting as host, with the iPhone, iPad and Android devices joining **[call]**
   - LiveKit (or a minimal forwarder) carried over an Iroh connection
   - **voice first:** 5 people in voice. Measure join time and latency, then kill the host and measure the gap.
   - **then the reference game night (§4.3)** on the same rig: add the screen share and cameras, and repeat the hand-over.

   This decides the media stack.
2. **Host reachability.** The community needs at least one reachable desktop. *Spike:* measure UPnP, hole-punch and relay rates across real home networks among the owner's friends, plus phone-hotspot and mobile-data tests for carrier-grade NAT. With fewer than about 5 distinct home networks, treat the numbers as anecdotal and run a wider beta before locking the media stack. **[call]**
3. **Group keys with members who are often offline.** MLS commits, removals and late joiners, combined with the signed admin log. *Spike:* model this before building chat.
4. **Phone background limits and push.** iOS wakes rarely, so push is required. Prove that the push relay plus an encrypted ping produces a reliable wake-and-fetch on iOS.
5. **LiveKit's assumptions** (domain/TLS, fixed server) may not fit. This is covered by spike 1.

---

## 9. Left to the builder
- Exact host-election algorithm, hand-over protocol and split-brain handling.
- Event and log formats, the merge rules for offline edits, and how long desktops keep the encrypted event log for members who are catching up.
- Invite and join mechanics (§4.5), within the stated security properties.
- Exact simulcast layers, bitrates and codec negotiation.
- The relay's caps and cost controls.
- UI layout and visual design, which should look and feel familiar to Discord users. The owner hasn't seen mockups yet, so plan a mockup review before building UI.
- Build order. A sensible order: spikes 1–3 → identity + sync + text chat on desktop → voice → screen share → mobile clients → push.

## 10. Open items outside the build
- The name "Hubbub" has no conflict with any current Discord alternative. A few old or small apps used it, and trademark registries, app stores and domains haven't been checked yet (`open-source-landscape.md`).
- The project-run push relay, fallback relay and invite page need a small, always-on host, a domain for invite links, and the owner's Apple/Google developer accounts.
