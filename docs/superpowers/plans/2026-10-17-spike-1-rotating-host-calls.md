# Spike 1: Calls Through a Rotating Host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, with measurements on the owner's real machines, that voice (first) and then a 1080p60 screen share with cameras (second) work through a rotating peer-to-peer host with automatic hand-over. Record which media stack Hubbub should keep.

**Architecture:**
- **Shared Rust core.** One `hubbub-core` crate runs on every device. It provides:
  - identity
  - a hand-distributed community file
  - Iroh control connections between members
  - a pure election state machine
  - the host role: it spawns a localhost-bound LiveKit server and tunnels LiveKit signaling over Iroh
- **Media path.** Members' Flutter apps use the LiveKit SDK against a `ws://127.0.0.1` tunnel the core provides. Media goes straight over UDP to the host's single LiveKit port.
- **Measurement.** Metrics go to local JSONL files, and a results document records the decision.

**Tech Stack:**
- Rust (stable), `iroh`, `tokio`, `serde_json`, `igd-next`, `livekit-api`, `hkdf`/`sha2`, `sysinfo`, `clap`
- `livekit-server` binary (Go, downloaded release)
- Flutter with `livekit_client` and `flutter_rust_bridge` v2

**Spec:** `docs/superpowers/specs/2026-10-16-hubbub-design.md`. §8 spike 1, plus the spike 2 tool. Executors read both.

## Global Constraints

### From the spec
- **Voice comes first.** Voice and text win trade-offs. Voice never gives up quality to make room for video. Under bandwidth pressure, cameras step down first and the screen share last.
- **Host election order:** (1) reachability, (2) connection quality to the other members (latency and stability), (3) upload bandwidth, (4) uptime.
- **Phones** never host, and never connect to each other directly.
- **Targets:**
  - Hand-over: the call resumes on a new host within 5 seconds.
  - Voice join: connects within 1 second of clicking. Mouth-to-ear under 150 ms on the same continent.
- **Reference game night:** 5 people in one voice channel, one 1080p60 screen share watched by the other 4, and up to 3 cameras at 540p30. Roughly 40 Mbps of host upload.
- **Video is only sent to people who actually clicked to watch.**
- **Attack surface:** only a hosting desktop listens for incoming connections. LiveKit's HTTP/WebSocket port is bound to `127.0.0.1`. No admin web panel.
- **Code safety:**
  - Memory-safe code in every networking, parsing and crypto path Hubbub writes. No `unsafe` in `hubbub-core`.
  - No telemetry. Metrics stay in local files.
- **License:** MIT.

### Spike-only exceptions (the product plans must remove these)
- n0's public Iroh relays and discovery are used.
- The E2EE key is derived from the community secret instead of MLS.
- The community file is copied between machines by hand instead of using invites.

### Machines (owner's)
- **Mac mini:** M1, macOS 27. This is the dev machine.
- **Windows desktop:** reached over ssh from the Mac, i9 / RTX 4060.
- **ThinkPad:** macOS and Linux dual boot.
- **Phones and tablets:** iPhone (iOS 27), iPad, Android (Onn tablet / AYN Thor).

### Agent rules (`~/.agents/AGENTS.md`)
- One heavy agent at a time.
- Any command that may run longer than 4 minutes (first Flutter or iOS builds, measurement runs) is handed back to the main session to run with `run_in_background`.

## Review Focus

The tests named below are added to their owning tasks.

1. **Host killed hard while someone shares their screen.** After hand-over, the sharer's share and mic come back automatically, without anyone re-clicking. Test: `handover_reconnects_and_republishes_mic_and_share` (Task 9).
2. **Network partition heals with two hosts.** Exactly one host remains, and the others follow it. Test: `partition_heal_two_hosts_converge` (Task 3).
3. **UPnP reports success but the router doesn't forward.** `reachable` must come from peers' observed direct connections, never from self-report. Test: `reachable_requires_peer_reports_not_self_report` (Task 4).
4. **Host laptop sleeps and wakes, still believing it hosts.** It must step down when it sees a higher term. Test: `stale_host_after_sleep_steps_down` (Task 3).
5. **Elected host can't start LiveKit** (binary missing, port in use). It must resign, so the next-best member hosts and no dead host remains. Test: `host_start_failure_resigns` (Task 7).

---

## File Structure

```
Cargo.toml                      workspace: core, cli, app/rust
rust-toolchain.toml             channel = "stable"
LICENSE                         MIT
.gitignore                      target/, vendor/, app/build/, *.jsonl
tools/fetch-livekit.sh          download + sha256-verify livekit-server into vendor/livekit/<os>-<arch>/
tools/livekit-version.txt       pinned livekit-server version
core/src/lib.rs                 module wiring, re-exports
core/src/ids.rs                 MemberId
core/src/identity.rs            device keypair on disk
core/src/community.rs           community file, membership, spike E2EE key
core/src/proto.rs               control messages + framing
core/src/net.rs                 Iroh endpoint, member-only accept, connection kind
core/src/election.rs            ranking + election state machine (pure)
core/src/view.rs                builds election candidates from peer reports
core/src/probe.rs               upload probe, median
core/src/upnp.rs                UDP port mapping
core/src/media_host.rs          MediaHost trait, LiveKitHost, FakeHost (test-only)
core/src/tunnel.rs              localhost TCP <-> Iroh stream piping
core/src/node.rs                Node: peers, election loop, host role, credentials, events
core/tests/handover.rs          3-node in-process hand-over tests
cli/src/main.rs                 `hubbub` binary: id, community, node, netcheck
app/                            Flutter app (all five platforms)
app/rust/src/api/hubbub.rs      flutter_rust_bridge API over hubbub-core
app/lib/main.dart
app/lib/node_controller.dart    wraps the Rust node, exposes state
app/lib/room_adapter.dart       RoomAdapter interface + LiveKitRoomAdapter
app/lib/voice_controller.dart   join/leave/mute/camera/share, hand-over reconnect
app/lib/metrics.dart            MetricsLogger (JSONL) + mouth-to-ear estimator
app/lib/ui/home_page.dart       status, channel, controls, participant grid
app/test/                       Dart unit tests
docs/spikes/spike-1-runbook.md  how to run each measurement scenario
docs/spikes/spike-1-results.md  measured table + decision
```

---

### Task 0: Toolchains, workspace skeleton, LiveKit binary

**Files:**
- Create: `Cargo.toml`, `rust-toolchain.toml`, `LICENSE`, `.gitignore`, `core/Cargo.toml`, `core/src/lib.rs`, `cli/Cargo.toml`, `cli/src/main.rs`
- Create: `tools/fetch-livekit.sh`, `tools/livekit-version.txt`

**Interfaces:**
- Produces:
  - the workspace that every later task adds to
  - `vendor/livekit/<os>-<arch>/livekit-server[.exe]`
  - `tools/fetch-livekit.sh <os> <arch>`, where os is `darwin|linux|windows` and arch is `arm64|amd64`

- [ ] **Step 1: Install Rust (rustup, stable) and Flutter (stable) on the Mac mini.** Verify with `cargo --version && flutter doctor`. Expected: both print versions. `flutter doctor` shows the Xcode and macOS desktop toolchains as OK.
- [ ] **Step 2: Install the same on the Windows desktop over SSH.** Install Rust and Flutter, plus the Visual Studio 2022 Build Tools with the "Desktop development with C++" workload.
  - If the Build Tools installer needs an interactive UAC prompt, stop and ask the owner to run it. This is an owner-only action.
  - Verify over ssh with `cargo --version && flutter doctor`.
- [ ] **Step 3: Install the same on the ThinkPad's Linux side.** Install Rust, Flutter, and the Linux desktop deps that `flutter doctor` lists. Ask the owner to boot it into Linux and confirm SSH access first.
- [ ] **Step 4: Create the workspace and licence.**
  - Create the workspace, with `core` as a lib crate and `cli` as a bin crate named `hubbub`.
  - Add the MIT `LICENSE`.
  - Pin the latest stable versions of the Tech Stack crates in `core/Cargo.toml`.
- [ ] **Step 5: Write the LiveKit fetch script.**
  - Write `tools/fetch-livekit.sh`. It downloads the release asset for the version in `tools/livekit-version.txt` (latest stable livekit-server) from `github.com/livekit/livekit/releases`.
  - It verifies the asset against the release's checksums file and exits non-zero on a mismatch.
  - It unpacks the binary into `vendor/livekit/<os>-<arch>/`.
- [ ] **Step 6: Check the binary runs on each desktop OS.** Run `tools/fetch-livekit.sh darwin arm64 && vendor/livekit/darwin-arm64/livekit-server --version`, then repeat for `windows amd64` on the Windows desktop (via Git Bash) and `linux amd64` on the ThinkPad.
  - Expected: a version string on all three.
  - If Windows has no release asset, record it in `docs/spikes/spike-1-results.md` under "Blockers". Windows then can't host, so it joins only as a member, and the decision section must address it.
- [ ] **Step 7: Run the empty build.** Run `cargo test --workspace`. Expected: PASS (0 tests).
- [ ] **Step 8: Commit.** `git add -A && git commit -m "chore: workspace skeleton, licence, livekit fetch script"`

---

### Task 1: Identity, MemberId, community file

**Files:**
- Create: `core/src/ids.rs`, `core/src/identity.rs`, `core/src/community.rs`
- Modify: `core/src/lib.rs`, `cli/src/main.rs`

**Interfaces:**
- Produces:
  - `pub struct MemberId(pub [u8; 32])`. It derives `Clone, Copy, Eq, Ord, Hash, Serialize, Deserialize` and serializes as 64-character lowercase hex.
  - `impl MemberId { pub fn tag(&self) -> String }`, which returns the first 4 hex characters in uppercase. `Display` and `FromStr` use hex.
  - `pub struct Identity` with `Identity::load_or_create(dir: &Path) -> anyhow::Result<Identity>`, `fn member_id(&self) -> MemberId` and `fn secret_key(&self) -> iroh::SecretKey`.
    - Storage: `<dir>/identity.key` holds 32 raw bytes. Mode 0600 on unix.
  - `pub struct CommunityFile { pub name: String, pub secret_hex: String, pub members: Vec<MemberEntry> }`
  - `pub struct MemberEntry { pub id: MemberId, pub name: String, pub can_host: bool }`
  - `CommunityFile` methods:
    - `create(name: &str) -> Self` makes a random 32-byte secret.
    - `load(path: &Path) -> anyhow::Result<Self>` and `save(&self, path: &Path) -> anyhow::Result<()>`.
    - `add_member(&mut self, e: MemberEntry)` replaces any entry with the same id.
    - `is_member(&self, id: &MemberId) -> bool`
    - `member(&self, id: &MemberId) -> Option<&MemberEntry>`
    - `e2ee_key(&self) -> [u8; 32]` is HKDF-SHA256 over the secret bytes, with `info = b"hubbub-spike-e2ee-v0"` and no salt.
  - CLI:
    - `hubbub id [--data-dir D]` prints `<hex> <TAG>`.
    - `hubbub community new <name> --out F`
    - `hubbub community add F <member-hex> <name> [--no-host]`
    - The default data dir is `~/.hubbub-spike`.

- [ ] **Step 1: Write the failing tests** in `core/src/identity.rs` and `core/src/community.rs`:

```rust
#[test] fn identity_persists_across_loads() {
    let d = tempfile::tempdir().unwrap();
    let a = Identity::load_or_create(d.path()).unwrap();
    let b = Identity::load_or_create(d.path()).unwrap();
    assert_eq!(a.member_id(), b.member_id());
}
#[test] fn tag_is_first_four_hex_upper() {
    let id = MemberId([0x4f, 0x2a, 0, 0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]);
    assert_eq!(id.tag(), "4F2A");
    assert_eq!(id.to_string().parse::<MemberId>().unwrap(), id);
}
#[test] fn community_roundtrip_membership_and_key() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("c.json");
    let mut c = CommunityFile::create("test");
    let id = Identity::load_or_create(d.path()).unwrap().member_id();
    c.add_member(MemberEntry { id, name: "mini".into(), can_host: true });
    c.save(&p).unwrap();
    let l = CommunityFile::load(&p).unwrap();
    assert!(l.is_member(&id));
    assert_eq!(l.e2ee_key(), c.e2ee_key());
    assert_ne!(CommunityFile::create("other").e2ee_key(), c.e2ee_key());
}
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core`. Expected: FAIL (unresolved items).
- [ ] **Step 3: Implement** the Interfaces above and the three CLI subcommands, using `clap` derive.
- [ ] **Step 4: Run the tests to see them pass.** Run `cargo test -p hubbub-core && cargo run -p hubbub-cli -- id --data-dir /tmp/hb-a`. Expected: PASS, and one line `<64 hex> <TAG>`.
- [ ] **Step 5: Commit.** `git commit -am "feat(core): identity, member ids, community file"`

---

### Task 2: Control protocol and member-only Iroh networking

**Files:**
- Create: `core/src/proto.rs`, `core/src/net.rs`

**Interfaces:**
- Consumes: `Identity`, `CommunityFile`, `MemberId` (Task 1).
- Produces:
  - ALPNs: `pub const ALPN_CTL: &[u8] = b"hubbub/ctl/0"` and `pub const ALPN_LK_SIGNAL: &[u8] = b"hubbub/lk-signal/0"`.
  - `pub enum CtlMsg`, serde-tagged as `"t"`:
    - `Hello { member: MemberId, can_host: bool, online_since_ms: u64 }`
    - `Ping { nonce: u64 }` and `Pong { nonce: u64 }`
    - `Report { about: Vec<PeerReport> }`
    - `Heartbeat { term: u64 }`
    - `Announce { term: u64, key: RankKey }`
    - `Resign { term: u64 }`
    - `TokenRequest { room: String }`
    - `TokenResponse { token: String }`
    - `TokenDenied { reason: String }`
    - `ProbeResult { mbps: u32 }`
  - `pub struct PeerReport { pub member: MemberId, pub rtt_ms: u32, pub direct: bool, pub upload_mbps: Option<u32> }`
  - `RankKey` is created in `core/src/election.rs` by this task, because `Announce` carries it. It has public fields and derives `Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize`. A greater value means a better candidate. Its fields, compared in order:
    1. `reachable: bool`
    2. `rtt: Reverse<u32>`, where the value is `median_rtt_ms / 10` (10 ms buckets)
    3. `upload: u32`, where the value is `upload_mbps / 10` (10 Mbps buckets)
    4. `age: Reverse<u64>`, where the value is `online_since_ms / 60_000` (1-minute buckets, earlier is better)
    5. `id: Reverse<MemberId>`

    Task 3 adds everything else in that file.
  - Framing: `pub async fn write_msg(s: &mut iroh::endpoint::SendStream, m: &CtlMsg) -> anyhow::Result<()>` and `pub async fn read_msg(r: &mut iroh::endpoint::RecvStream) -> anyhow::Result<Option<CtlMsg>>`.
    - Each frame is a u32 big-endian length followed by JSON.
    - The maximum frame is 65,536 bytes. A larger length is an error, and the stream is closed.
  - `pub enum RelayChoice { N0Default, Disabled }`
  - `pub enum ConnKind { Direct, Relay, Unknown }`
  - `pub struct Net`, with:
    - `async fn bind(id: &Identity, community: Arc<CommunityFile>, relay: RelayChoice) -> anyhow::Result<Net>`
    - `fn member_id(&self) -> MemberId`
    - `async fn addr(&self) -> anyhow::Result<iroh::NodeAddr>`, for tests (use whatever the current iroh address type is called)
    - `async fn connect(&self, to: MemberId, alpn: &[u8]) -> anyhow::Result<iroh::endpoint::Connection>`
    - `async fn connect_addr(&self, to: iroh::NodeAddr, alpn: &[u8]) -> anyhow::Result<iroh::endpoint::Connection>`
    - `async fn accept(&self) -> Option<(MemberId, Vec<u8>, iroh::endpoint::Connection)>`. It returns only connections from members, with a known ALPN. Others are closed with application code 403 and skipped.
    - `fn conn_kind(&self, to: MemberId) -> ConnKind`

- [ ] **Step 1: Write the failing tests** in `core/src/net.rs`:

```rust
#[tokio::test] async fn member_connects_and_exchanges_msg() {
    let (a, b) = two_member_nets().await;   // helper: tempdir identities, shared community, RelayChoice::Disabled
    let conn = a.connect_addr(b.addr().await.unwrap(), ALPN_CTL).await.unwrap();
    let (mut s, _r) = conn.open_bi().await.unwrap();
    write_msg(&mut s, &CtlMsg::Ping { nonce: 7 }).await.unwrap();
    let (who, alpn, c) = b.accept().await.unwrap();
    assert_eq!(who, a.member_id()); assert_eq!(alpn, ALPN_CTL);
    let (_s2, mut r2) = c.accept_bi().await.unwrap();
    assert!(matches!(read_msg(&mut r2).await.unwrap(), Some(CtlMsg::Ping { nonce: 7 })));
}
#[tokio::test] async fn non_member_connection_is_rejected() {
    let (_a, b) = two_member_nets().await;
    let stranger = stranger_net().await;    // identity not in community
    let conn = stranger.connect_addr(b.addr().await.unwrap(), ALPN_CTL).await.unwrap();
    let accepted = tokio::time::timeout(Duration::from_millis(500), b.accept()).await;
    assert!(accepted.is_err(), "stranger must never be yielded by accept()");
    assert!(conn.closed().await.to_string().contains("403"));
}
#[tokio::test] async fn oversized_frame_is_an_error() { /* write a raw u32 length of 65_537 then read_msg → Err */ }
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core net::`. Expected: FAIL.
- [ ] **Step 3: Implement** `proto.rs` and `net.rs` as specified.
  - Build the iroh endpoint with the identity's secret key and both ALPNs.
  - `RelayChoice::N0Default` turns on iroh's default relays and discovery (spike only). `Disabled` turns them off, for tests.
  - Map `conn_kind` from iroh's connection-type API.
- [ ] **Step 4: Run the tests to see them pass.** Run `cargo test -p hubbub-core net::`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(core): member-only iroh networking and control framing"`

---

### Task 3: Election state machine

**Files:**
- Create/complete: `core/src/election.rs`

**Interfaces:**
- Consumes: `MemberId`.
- Produces:
  - Timing constants: `pub const HEARTBEAT_MS: u64 = 500; pub const HOST_TIMEOUT_MS: u64 = 1_500; pub const STARTUP_GRACE_MS: u64 = 1_500;`
  - `pub struct Candidate { pub member: MemberId, pub can_host: bool, pub reachable: bool, pub median_rtt_ms: u32, pub upload_mbps: u32, pub online_since_ms: u64 }`
  - `pub fn rank_key(c: &Candidate) -> RankKey`, using the `RankKey` from Task 2.
  - `pub fn best(view: &[Candidate]) -> Option<MemberId>` ignores candidates with `can_host == false`.
  - `pub struct HostState { pub host: Option<MemberId>, pub term: u64 }`
  - `pub enum Input`:
    - `Tick { now_ms: u64 }`
    - `Heartbeat { from: MemberId, term: u64, now_ms: u64 }`
    - `Announce { from: MemberId, term: u64, key: RankKey, now_ms: u64 }`
    - `Resign { from: MemberId, term: u64, now_ms: u64 }`
    - `PeerDown { member: MemberId, now_ms: u64 }`
  - `pub enum Action`, which derives `Debug, PartialEq`:
    - `StartHosting { term: u64 }`
    - `StopHosting`
    - `SendHeartbeat { term: u64 }`
    - `SendAnnounce { term: u64, key: RankKey }`
    - `HostChanged(HostState)`
  - `pub struct Election`, with `fn new(me: MemberId, can_host: bool, started_ms: u64) -> Self`, `fn step(&mut self, input: Input, view: &[Candidate]) -> Vec<Action>` and `fn state(&self) -> &HostState`.
- Rules the implementation must follow:
  1. **No claims during startup grace.** A node never claims within `STARTUP_GRACE_MS` of `started_ms`. This gives it time to hear an existing host.
  2. **Accepting a host.** A `Heartbeat` or `Announce` with `term` greater than the current term is accepted. That sender becomes the host. If this node was hosting, it emits `StopHosting`.
  3. **No preemption.** A better newcomer never displaces a host that is sending heartbeats.
  4. **Host timeout.** If the host is silent for more than `HOST_TIMEOUT_MS`, or a `PeerDown`/`Resign` arrives for the host, the host is cleared.
     - The node then computes `best(view)` with the old host excluded.
     - If the result is this node, it claims `term = max_seen_term + 1` and emits `StartHosting`, `SendAnnounce` and `HostChanged`.
  5. **Same-term conflict.** If two nodes host at the same term, the higher `RankKey` keeps hosting. The lower one emits `StopHosting` and accepts the winner.
  6. **Heartbeats.** While hosting, the node emits `SendHeartbeat` on every `Tick` that is at least `HEARTBEAT_MS` after the previous one.
  7. **Phones.** A node with `can_host == false` never emits `StartHosting`.

- [ ] **Step 1: Write the failing tests.** Use helper `cand(id_byte, reachable, rtt, up, since) -> Candidate` and `m(n) -> MemberId`.

```rust
#[test] fn rank_orders_reachable_then_rtt_then_upload_then_uptime_then_id() {
    let v = [cand(1,false,5,900,0), cand(2,true,80,10,0), cand(3,true,20,10,0), cand(4,true,20,50,0)];
    assert_eq!(best(&v), Some(m(4)));
}
#[test] fn rtt_bucket_10ms_prevents_flap() {
    assert_eq!(rank_key(&cand(1,true,21,10,0)).rtt, rank_key(&cand(1,true,29,10,0)).rtt);
}
#[test] fn single_desktop_claims_after_grace() {
    let mut e = Election::new(m(1), true, 0); let v = [cand(1,true,0,0,0)];
    assert!(e.step(Input::Tick{now_ms:1_000}, &v).is_empty());
    let a = e.step(Input::Tick{now_ms:1_600}, &v);
    assert!(a.contains(&Action::StartHosting{term:1}));
}
#[test] fn phone_never_claims() {
    let mut e = Election::new(m(1), false, 0);
    assert!(!e.step(Input::Tick{now_ms:10_000}, &[cand_phone(1)]).iter().any(|a| matches!(a, Action::StartHosting{..})));
}
#[test] fn better_newcomer_does_not_preempt() { /* host m(2) heartbeating at term 3; m(1) is strictly better in view; m(1) ticks for 5s while heartbeats arrive every 500ms → never StartHosting */ }
#[test] fn host_timeout_triggers_reelection_by_best() { /* m(2) hosts term 3, last heartbeat at t=0; m(1) (best remaining) at Tick{1_600} → StartHosting{term:4} */ }
#[test] fn graceful_resign_reelects_immediately() { /* Resign{from: host, term:3} → same tick StartHosting{term:4} for best */ }
#[test] fn split_brain_same_term_higher_key_wins() { /* m(1) hosting term 4; Announce{from:m(2), term:4, key: better} → StopHosting + HostChanged(host=m(2)) */ }
#[test] fn higher_term_announce_wins() { /* hosting term 4; Announce term 5 from worse candidate → StopHosting, host = sender */ }
#[test] fn partition_heal_two_hosts_converge() { /* two Elections each hosting term 4 after a partition; exchange Announce both ways; exactly one still hosting */ }
#[test] fn stale_host_after_sleep_steps_down() { /* m(1) hosted term 2, no ticks for 60s (sleep); then Heartbeat{from:m(3), term:3} → StopHosting, host = m(3) */ }
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core election::`. Expected: FAIL.
- [ ] **Step 3: Implement** `Election` according to the rules above. `max_seen_term` tracks every term seen in any input.
- [ ] **Step 4: Run the tests to see them pass.** Run `cargo test -p hubbub-core election::`. Expected: PASS (11 tests).
- [ ] **Step 5: Commit.** `git commit -am "feat(core): host election state machine"`

---

### Task 4: Peer-measured view, upload probe, UPnP

**Files:**
- Create: `core/src/view.rs`, `core/src/probe.rs`, `core/src/upnp.rs`

**Interfaces:**
- Consumes: `PeerReport`, `Candidate`, `MemberId`.
- Produces:
  - `pub fn median(xs: &[u32]) -> Option<u32>` returns the lower median for even lengths.
  - `pub fn build_view(me: &MemberId, online: &[(MemberId, bool /*can_host*/, u64 /*online_since_ms*/)], reports: &HashMap<MemberId /*reporter*/, Vec<PeerReport>>) -> Vec<Candidate>`. For each candidate X:
    - `median_rtt_ms` is the median of other members' reported `rtt_ms` about X.
    - `upload_mbps` is the median of the `upload_mbps` values others report about X.
    - `reachable` is true when more than half of X's reporters say `direct == true`.
    - With no reports about X, all three are zero/false.
    - What X says about itself is never used.
  - Probe constants and functions:
    - `pub const PROBE_BYTES: u64 = 8 * 1024 * 1024;`
    - `pub fn mbps(bytes: u64, elapsed: Duration) -> u32` uses `bytes * 8 / elapsed_micros`.
    - `pub async fn send_probe(conn: &iroh::endpoint::Connection) -> anyhow::Result<()>` opens a uni stream and writes `PROBE_BYTES` zero bytes.
    - `pub async fn recv_probe(r: iroh::endpoint::RecvStream) -> anyhow::Result<u32>` returns the receiver-measured Mbps.
  - UPnP:
    - `pub struct Mapping { pub external_ip: IpAddr, pub external_port: u16, pub local_port: u16 }`
    - `pub async fn map_udp(local_port: u16, lifetime_s: u32) -> anyhow::Result<Mapping>` uses `igd-next` with the tokio feature and a 3-second search timeout. It maps to the same external port, using description `"hubbub"`.
    - `pub async fn unmap_udp(m: &Mapping) -> anyhow::Result<()>`

- [ ] **Step 1: Write the failing tests:**

```rust
#[test] fn median_lower_for_even() { assert_eq!(median(&[40, 10, 30, 20]), Some(20)); assert_eq!(median(&[]), None); }
#[test] fn mbps_math() { assert_eq!(mbps(10_000_000, Duration::from_secs(1)), 80); }
#[test] fn reachable_requires_peer_reports_not_self_report() {
    // X reports about itself direct=true; two others report direct=false → reachable=false
    let v = build_view(&m(9), &online3(), &reports_where_x_self_claims_direct());
    assert!(!v.iter().find(|c| c.member == m(1)).unwrap().reachable);
}
#[test] fn rtt_and_upload_are_medians_of_others() { /* 3 reporters about X: rtt 10,30,50 up 20,40,60 → 30 / 40 */ }
#[tokio::test] async fn probe_measures_nonzero_in_process() { /* two Nets from Task 2 helper, send_probe → recv_probe > 0 */ }
#[tokio::test] #[ignore = "needs a UPnP router"] async fn upnp_maps_and_unmaps() { /* map_udp(47882, 120) then unmap */ }
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core -- view:: probe:: upnp::`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run the tests to see them pass.** Run the same command. Expected: PASS, with 1 ignored. Then run `cargo test -p hubbub-core upnp -- --ignored` on the Mac mini and record the result in the commit message (works or fails on the home router).
- [ ] **Step 5: Commit.** `git commit -am "feat(core): peer-measured election view, upload probe, upnp"`

---

### Task 5: Media host (LiveKit) and token minting

**Files:**
- Create: `core/src/media_host.rs`

**Interfaces:**
- Consumes: `MemberId`.
- Produces:
  - The trait:

    ```rust
    #[async_trait::async_trait]
    pub trait MediaHost: Send + Sync {
        async fn start(&mut self, node_ip: IpAddr) -> anyhow::Result<SocketAddr>; // returns 127.0.0.1 signal addr
        async fn stop(&mut self);
        fn mint(&self, member: &MemberId, name: &str, room: &str) -> anyhow::Result<String>;
    }
    ```

  - Ports and config:
    - `pub struct LkPorts { pub signal: u16, pub rtc_tcp: u16, pub rtc_udp: u16 }`. Defaults are `7880 / 7881 / 7882`.
    - `pub fn render_config(ports: &LkPorts, node_ip: IpAddr, api_key: &str, api_secret: &str) -> String`
  - `pub struct LiveKitHost { bin: PathBuf, work_dir: PathBuf, ports: LkPorts, key: String, secret: String, child: Option<tokio::process::Child> }`
    - `LiveKitHost::new(bin, work_dir, ports)` generates a random API key (`"hb" + 14 alphanumeric characters`) and secret (43 alphanumeric characters) on each `new`.
    - `start` writes `<work_dir>/livekit.yaml` and spawns `bin --config <file>` with `kill_on_drop(true)`.
    - It polls `GET http://127.0.0.1:<signal>/` until it returns 200, every 50 ms for up to 5 s. Otherwise it returns an error.
  - Tokens: `mint` uses `livekit-api` `AccessToken` with:
    - identity = member hex, name = `name`
    - grants: `room_join`, `room`, `can_publish`, `can_subscribe`, `can_publish_data`
    - TTL of 6 h
  - `#[cfg(any(test, feature = "test-util"))] pub struct FakeHost`
    - `start` binds a TCP echo server on `127.0.0.1:0` and returns its address.
    - `mint` returns `format!("fake:{member}:{room}")`.
    - `FakeHost::failing()` makes `start` return an error.
- The rendered YAML must contain exactly these settings:

```yaml
port: {signal}
bind_addresses: ["127.0.0.1"]
rtc:
  tcp_port: {rtc_tcp}
  udp_port: {rtc_udp}
  use_external_ip: false
  node_ip: {node_ip}
keys:
  {api_key}: {api_secret}
logging:
  level: info
```

- [ ] **Step 1: Write the failing tests:**

```rust
#[test] fn render_config_pins_localhost_signal_and_single_udp_port() {
    let y = render_config(&LkPorts::default(), "192.168.1.20".parse().unwrap(), "hbK", "S");
    assert!(y.contains("bind_addresses: [\"127.0.0.1\"]"));
    assert!(y.contains("udp_port: 7882")); assert!(y.contains("node_ip: 192.168.1.20"));
    assert!(y.contains("use_external_ip: false"));
}
#[test] fn minted_token_has_identity_room_and_grants() {
    let h = LiveKitHost::new("x".into(), std::env::temp_dir(), LkPorts::default());
    let t = h.mint(&m(1), "mini", "lobby").unwrap();
    let claims = decode_unverified(&t);           // jsonwebtoken dangerous_insecure_decode helper
    assert_eq!(claims["sub"], m(1).to_string());
    assert_eq!(claims["video"]["room"], "lobby"); assert_eq!(claims["video"]["roomJoin"], true);
}
#[tokio::test] #[ignore = "needs LIVEKIT_BIN"] async fn livekit_starts_and_signal_is_localhost_only() {
    // start real binary from env LIVEKIT_BIN; assert health 200 on 127.0.0.1:7880;
    // assert TCP connect to <LAN ip>:7880 fails; assert UDP 7882 is bound (via `lsof -nP -iUDP:7882` on unix)
}
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core media_host::`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run the tests to see them pass.** Run `cargo test -p hubbub-core media_host::`. Expected: PASS. Then run `LIVEKIT_BIN=$PWD/vendor/livekit/darwin-arm64/livekit-server cargo test -p hubbub-core media_host -- --ignored`. Expected: PASS.
  - If LiveKit also binds 7880 on the LAN despite `bind_addresses`, stop and record it as a security blocker in the results doc. Do not work around it silently.
- [ ] **Step 5: Commit.** `git commit -am "feat(core): livekit media host and tokens"`

---

### Task 6: Signal tunnel

**Files:**
- Create: `core/src/tunnel.rs`

**Interfaces:**
- Consumes: `Net`, `ALPN_LK_SIGNAL`.
- Produces:
  - `pub async fn serve_local<F, Fut>(listener: tokio::net::TcpListener, open: F) -> anyhow::Result<()>`, where `F: Fn() -> Fut + Send + Sync + 'static` and `Fut: Future<Output = anyhow::Result<(SendStream, RecvStream)>> + Send`.
    - For each accepted TCP connection it calls `open()` and pipes in both directions until either side closes.
    - It calls `open()` per TCP connection, so a host change takes effect on the next connection.
  - `pub async fn serve_host(conn: iroh::endpoint::Connection, target: SocketAddr) -> anyhow::Result<()>`. For each accepted bi stream it opens `TcpStream::connect(target)` and pipes.

- [ ] **Step 1: Write the failing tests:**

```rust
#[tokio::test] async fn tunnel_round_trips_bytes() {
    // host: TCP echo on 127.0.0.1:0; b accepts ALPN_LK_SIGNAL → serve_host(conn, echo_addr)
    // client: listener 127.0.0.1:0 → serve_local(listener, || a.connect_addr(b_addr, ALPN_LK_SIGNAL).open_bi())
    // write b"hello" to the local port, expect b"hello" back within 1s
}
#[tokio::test] async fn tunnel_reports_close_when_target_down() { /* target port closed → local TCP read returns 0 (EOF) within 1s */ }
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core tunnel::`. Expected: FAIL.
- [ ] **Step 3: Implement** using `tokio::io::copy` in both directions with `tokio::try_join!`, and shut down the write halves on EOF.
- [ ] **Step 4: Run the tests to see them pass.** Run the same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(core): livekit signal tunnel over iroh"`

---

### Task 7: Node orchestration and hand-over integration tests

**Files:**
- Create: `core/src/node.rs`, `core/tests/handover.rs`
- Modify: `cli/src/main.rs` to add the `hubbub node` subcommand

**Interfaces:**
- Consumes: everything in Tasks 1–6.
- Produces:
  - `pub struct NodeConfig { pub data_dir: PathBuf, pub community_file: PathBuf, pub can_host: bool, pub relay: RelayChoice }`
  - `pub enum NodeEvent`, which derives `Clone, Debug`:
    - `HostChanged { host: Option<MemberId>, term: u64, is_me: bool }`
    - `PeerUp { member: MemberId, kind: ConnKind }`
    - `PeerDown { member: MemberId }`
  - `pub struct VoiceCredentials { pub url: String, pub token: String, pub e2ee_key: [u8; 32], pub host: MemberId, pub term: u64 }`
  - `pub struct Node`, with:
    - `async fn start(cfg: NodeConfig, media: Box<dyn MediaHost>) -> anyhow::Result<Node>`
    - `fn member_id(&self) -> MemberId`
    - `fn subscribe(&self) -> tokio::sync::broadcast::Receiver<NodeEvent>`
    - `fn host_state(&self) -> HostState`
    - `async fn voice_credentials(&self, room: &str) -> anyhow::Result<VoiceCredentials>`
    - `async fn shutdown(self)`
    - `#[cfg(feature = "test-util")] async fn start_with_addrs(cfg, media, peers: Vec<iroh::NodeAddr>) -> anyhow::Result<Node>`, for in-process tests with relays disabled.
  - CLI: `hubbub node --community F [--data-dir D] [--livekit-bin B] [--no-host] [--print-lk-keys]`
    - It prints each `NodeEvent` as one JSON line.
    - `--print-lk-keys` prints the host's API key and secret when it starts hosting, for `lk load-test` on the host machine.
    - Ctrl-C triggers `shutdown`.
- Behaviour to implement:
  - **Peers.** The node connects to every other member over `ALPN_CTL`, retrying with backoff from 1 s up to 10 s.
  - **Per-peer session.**
    - It starts with `Hello`.
    - It sends `Ping` every 1 s and keeps an RTT EWMA with α = 0.3.
    - It sends `send_probe` once after `Hello`, and the receiving side answers `ProbeResult`.
    - Every 2 s it sends `Report` covering its peers. That report includes each peer's `direct` flag from `conn_kind`.
  - **Election loop.** It ticks every 100 ms, feeds `build_view` into `Election::step`, and carries out the resulting actions.
  - **On `StartHosting`:**
    1. Try `map_udp(rtc_udp, 3600)`, renewing at 1800 s.
    2. Set `node_ip` to the mapping's external IP if mapping worked, otherwise the first private LAN IPv4.
    3. Call `media.start(node_ip)`. If that fails, send `Resign { term }` to all peers, mark itself `can_host = false` for 60 s, and emit `HostChanged { host: None }`.
    4. Accept `ALPN_LK_SIGNAL` connections from members and `serve_host` them to the signal address.
  - **Token requests.** When hosting, the node answers a `TokenRequest` from a member with `media.mint(...)`. A request when it isn't hosting gets `TokenDenied { reason: "not host" }`.
  - **`voice_credentials`:**
    - On the host, it returns `ws://127.0.0.1:<signal>` and mints locally.
    - On anyone else, it requests a token from the current host over the ctl stream and returns `ws://127.0.0.1:<local tunnel port>`. The single local tunnel listener is bound once at start, and its `open` closure targets the current host.
    - `e2ee_key` is `community.e2ee_key()`.
  - **`shutdown`.** If hosting, it sends `Resign`, then `media.stop()` and `unmap_udp`.

- [ ] **Step 1: Write the failing integration tests** in `core/tests/handover.rs`. Use helper `cluster(n, can_host: &[bool], fail_start: &[bool]) -> Vec<Node>`, which shares one community, uses `FakeHost` and passes peer addrs:

```rust
#[tokio::test] async fn three_nodes_agree_on_one_host() {
    let ns = cluster(3, &[true;3], &[false;3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;   // all host_state().host equal & Some
    assert_eq!(ns.iter().filter(|n| n.host_state().host == Some(n.member_id())).count(), 1);
    let _ = host;
}
#[tokio::test] async fn hard_kill_handover_under_2_5s_and_creds_follow() {
    let mut ns = cluster(3, &[true;3], &[false;3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    let t0 = Instant::now(); drop_node_without_resign(&mut ns, host);
    let new_host = wait_agree(&ns, Duration::from_millis(2_500)).await;
    assert_ne!(new_host, host); assert!(t0.elapsed() < Duration::from_millis(2_500));
    let follower = ns.iter().find(|n| n.member_id() != new_host).unwrap();
    let c = follower.voice_credentials("lobby").await.unwrap();
    assert_eq!(c.token, format!("fake:{}:lobby", follower.member_id()));
    assert_eq!(echo_via(&c.url, b"ping").await, b"ping");      // tunnel reaches the new host's FakeHost
}
#[tokio::test] async fn graceful_shutdown_handover_under_1s() { /* shutdown() on host → new host agreed < 1s */ }
#[tokio::test] async fn phone_member_never_hosts() { /* cluster(2, &[true,false]) → host is node 0; kill node 0 → host None, node 1 HostChanged{host:None} */ }
#[tokio::test] async fn host_start_failure_resigns() { /* cluster(2, &[true,true], fail_start=[the would-be winner]) → the other node ends up host within 4s */ }
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cargo test -p hubbub-core --features test-util --test handover`. Expected: FAIL.
- [ ] **Step 3: Implement** `Node` and the CLI subcommand as specified.
- [ ] **Step 4: Run the tests to see them pass.** Run `cargo test -p hubbub-core --features test-util --test handover`. Expected: PASS (5 tests), with no flakes over `for i in $(seq 10); do cargo test ... || break; done`.
- [ ] **Step 5: Run the real two-machine smoke test.**
  - Build `hubbub` on the Mac mini and the Windows desktop.
  - Put both ids in one community file and copy it to both machines.
  - Run `hubbub node --community c.json --livekit-bin vendor/...` on each machine.
  - Expected: both print the same `HostChanged`. When you Ctrl-C the host, the other prints `HostChanged { is_me: true }` within 5 s.
- [ ] **Step 6: Commit.** `git commit -am "feat(core): node orchestration with rotating host and hand-over"`

---

### Task 8: Flutter app with in-process core — voice on desktop

**Files:**
- Create: the `app/` Flutter project (platforms: macos, windows, linux, ios, android), `app/rust/` (flutter_rust_bridge integrate), `app/rust/src/api/hubbub.rs`
- Create: `app/lib/main.dart`, `app/lib/node_controller.dart`, `app/lib/room_adapter.dart`, `app/lib/ui/home_page.dart`
- Modify: root `Cargo.toml` to add the `app/rust` workspace member

**Interfaces:**
- Consumes: `Node`, `NodeConfig`, `NodeEvent`, `VoiceCredentials`, `LiveKitHost` (Task 7).
- Produces:
  - **Rust API (FRB):**
    - `pub struct AppNodeConfig { pub data_dir: String, pub community_file: String, pub can_host: bool, pub livekit_bin: Option<String> }`
    - `#[frb(opaque)] pub struct AppNode`
    - `pub async fn start_node(cfg: AppNodeConfig) -> anyhow::Result<AppNode>`. It uses `LiveKitHost` when `livekit_bin` is `Some`. Otherwise it uses a host that always fails, so phones are never chosen.
    - Node functions:
      - `pub fn node_member_id(n: &AppNode) -> String`
      - `pub fn node_events(n: &AppNode, sink: StreamSink<AppNodeEvent>) -> anyhow::Result<()>`
      - `pub async fn node_voice_credentials(n: &AppNode, room: String) -> anyhow::Result<AppVoiceCredentials>`
      - `pub async fn node_shutdown(n: AppNode)`
      - `pub fn process_cpu_percent() -> f32`, via `sysinfo`
    - Data types:
      - `pub struct AppVoiceCredentials { pub url: String, pub token: String, pub e2ee_key: Vec<u8>, pub host: String, pub term: u64 }`
      - `pub enum AppNodeEvent { HostChanged { host: Option<String>, term: u64, is_me: bool }, PeerUp { member: String, direct: bool }, PeerDown { member: String } }`
  - **Dart:**

    ```dart
    abstract class RoomAdapter {
      Future<void> connect(String url, String token, Uint8List e2eeKey);
      Future<void> disconnect();
      Future<void> setMicrophoneEnabled(bool on);
      Future<void> setCameraEnabled(bool on);
      Future<void> setScreenShareEnabled(bool on, {String? sourceId});
      Future<void> subscribeVideo(String participantId, String trackSid, bool on);
      Stream<RoomSignal> get signals; // RoomSignal.disconnected | firstRemoteAudio | stats(StatsSample) | videoRx(VideoRxSample)
    }
    class LiveKitRoomAdapter implements RoomAdapter { ... }
    class NodeController extends ChangeNotifier {
      Future<void> start(AppNodeConfig cfg);
      String? get memberId; String? get host; int get term; bool get isHost;
      Stream<AppNodeEvent> get events;
      Future<AppVoiceCredentials> credentials(String room);
    }
    ```

  - **`LiveKitRoomAdapter` settings:**
    - `ConnectOptions(autoSubscribe: false)`
    - Audio tracks are subscribed on `TrackPublished`. Video is subscribed only through `subscribeVideo`, i.e. after a click to watch.
    - `RoomOptions(adaptiveStream: true, dynacast: true, e2eeOptions: E2EEOptions(keyProvider: shared key = base64(e2eeKey)))`
    - Audio capture defaults: noise suppression, echo cancellation and auto gain on.
- Community file import: the home page has an "Import community file" button (file_picker), and it shows `memberId` and its tag, selectable so they can be copied into the file.
- The macOS app needs mic/camera usage strings, screen-recording permission, and the network client/server entitlements.

- [ ] **Step 1: Write the failing test.** In `app/test/node_controller_test.dart`, `host_changed_event_updates_state`: feed a fake event stream `HostChanged(host:'ab..', term:2, isMe:false)` and expect `controller.host == 'ab..'`, `term == 2` and `isHost == false`.
- [ ] **Step 2: Run the test to see it fail.** Run `cd app && flutter test test/node_controller_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the FRB API, `NodeController` (it takes an injectable event stream for tests), `LiveKitRoomAdapter`, and a minimal `HomePage`. The home page shows:
  - the host name with a "you are host" badge
  - a "lobby" voice channel join/leave button
  - mute, and a participant list with speaking indicators
  - The macOS desktop build bundles `vendor/livekit/darwin-arm64/livekit-server` as an app resource and passes its path as `livekit_bin`.
- [ ] **Step 4: Run the tests and the build.** Run `flutter test && flutter build macos`. Expected: PASS and a built app. The first build may take more than 4 minutes, so hand it to the main session.
- [ ] **Step 5: Run the manual voice check (owner present).** Run the macOS app on the Mac mini and on the ThinkPad (macOS side). Both join "lobby", and each hears the other. Both show the same host.
- [ ] **Step 6: Commit.** `git commit -am "feat(app): flutter app with in-process core, voice on desktop"`

---

### Task 9: Voice controller, hand-over reconnect, metrics

**Files:**
- Create: `app/lib/voice_controller.dart`, `app/lib/metrics.dart`, `app/test/voice_controller_test.dart`, `app/test/metrics_test.dart`

**Interfaces:**
- Consumes: `RoomAdapter`, `NodeController`, `AppVoiceCredentials`, `AppNodeEvent`.
- Produces:
  - Metrics:

    ```dart
    typedef Clock = DateTime Function();
    int estMouthToEarMs({required int senderRttMs, required int receiverRttMs, required int jitterBufferMs}) =>
        senderRttMs ~/ 2 + receiverRttMs ~/ 2 + jitterBufferMs + 40; // 40 = capture/encode + playout allowance (estimate)
    class MetricsLogger { MetricsLogger(String path, Clock clock); void log(String kind, Map<String, Object?> fields); Future<void> close(); }
    ```

    - Each line is JSON: `{"t":<epoch ms>,"kind":...,...}`.
    - Kinds: `join` (`ms`), `handover` (`gap_ms`, `from_term`, `to_term`), `stats` (`rtt_ms`, `jitter_ms`, `jb_ms`, `est_m2e_ms`, `loss_pct`, `peer`), `video_rx` (`source` = screen|camera, `w`, `h`, `fps`, `kbps`), `cpu` (`pct`).
    - The file is `<data_dir>/metrics-<yyyyMMdd-HHmm>.jsonl`.
  - Voice controller:

    ```dart
    class VoiceController extends ChangeNotifier {
      VoiceController(RoomAdapter room, Future<AppVoiceCredentials> Function(String room) creds, MetricsLogger metrics, Clock clock);
      Future<void> join(String room);    // logs join: click → first remote audio (or connected+mic published if alone)
      Future<void> leave();
      Future<void> setMic(bool on); Future<void> setCamera(bool on); Future<void> setShare(bool on, {String? sourceId});
      Future<void> onHostChanged(int newTerm);   // reconnect to new creds, restore mic/camera/share state, log handover
      bool get micOn; bool get cameraOn; bool get sharing; bool get inCall;
    }
    ```

  - Each client publishes its own RTT as LiveKit participant attribute `rtt_ms` every 2 s, so receivers can compute `est_m2e_ms`. It also samples `process_cpu_percent()` every 2 s and logs `cpu`.
  - The hand-over gap runs from the earlier of `RoomSignal.disconnected` or the `HostChanged` receipt, to the first `firstRemoteAudio` after reconnecting.

- [ ] **Step 1: Write the failing tests:**

```dart
test('estimator matches formula', () => expect(estMouthToEarMs(senderRttMs: 40, receiverRttMs: 60, jitterBufferMs: 30), 120));
test('join_records_join_ms', () async { /* fake clock +350ms between join() and firstRemoteAudio → metrics line kind=join ms=350 */ });
test('handover_reconnects_and_republishes_mic_and_share', () async {
  // join, setMic(true), setShare(true, sourceId:'s1'); fake emits disconnected at t=0;
  // onHostChanged(2) with creds url 'ws://127.0.0.1:2' ; fake emits firstRemoteAudio at t=1800ms
  // expect fake.connectCalls.last.url == 'ws://127.0.0.1:2'; mic and share re-enabled with sourceId 's1';
  // metrics has kind=handover gap_ms=1800 from_term=1 to_term=2
});
test('leave_then_host_change_does_not_reconnect', () async { /* not in call → onHostChanged is a no-op */ });
```

- [ ] **Step 2: Run the tests to see them fail.** Run `cd app && flutter test test/voice_controller_test.dart test/metrics_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** both classes. Then wire `NodeController.events` `HostChanged` into `VoiceController.onHostChanged`, and add stats sampling every 2 s from LiveKit's stats API.
- [ ] **Step 4: Run the tests to see them pass.** Run the same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(app): voice controller with hand-over reconnect and local metrics"`

---

### Task 10: Screen share and cameras

**Files:**
- Modify: `app/lib/room_adapter.dart`, `app/lib/voice_controller.dart`, `app/lib/ui/home_page.dart`
- Create: `app/lib/ui/participant_tile.dart`

**Interfaces:**
- Consumes: `RoomAdapter.setScreenShareEnabled`, `subscribeVideo`, `VoiceController.setShare/setCamera`.
- Produces:
  - **Screen share capture (spec values):**
    - 1920×1080, `maxFramerate: 60`, `maxBitrate: 6_000_000`
    - simulcast layers 720p30 at 2.5 Mbps and 360p15 at 0.6 Mbps
    - preferred codec `av1` with backup codec `h264`
    - with the app's audio included where the platform allows it
  - **Cameras:** 960×540 at 30 fps, `maxBitrate: 1_000_000`, with simulcast layer 360p15. Cameras degrade before the screen share: set the screen share's `degradationPreference` to maintain resolution and the camera's to balanced.
  - **UI:**
    - A "Share screen" button opens the desktop source picker.
    - Each participant tile shows a "Watch" button when that person is sharing. Tapping it calls `subscribeVideo(..., true)`, and closing calls it with `false`.
    - The video-rx overlay shows the received resolution, fps and kbps, and those values go to `video_rx` metrics every 2 s.

- [ ] **Step 1: Write the failing test.** In `app/test/voice_controller_test.dart`, `watch_subscribes_only_on_click`: after `join`, the fake receives no `subscribeVideo(on: true)` calls. After `watch('p2','TR_s')` it receives exactly one. After `unwatch` it receives an `off` call.
- [ ] **Step 2: Run the test to see it fail.** Run `flutter test test/voice_controller_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the values above. Add `watch(String participantId, String trackSid)` and `unwatch(...)` to `VoiceController`.
- [ ] **Step 4: Run the tests and the build.** Run `flutter test && flutter build macos`. Expected: PASS.
- [ ] **Step 5: Run the manual check (owner present).** The Mac mini shares a screen with a 60 fps test video. The ThinkPad watches it, and its overlay shows 1920×1080 at about 60 fps. Write down the actual numbers in the commit message.
- [ ] **Step 6: Commit.** `git commit -am "feat(app): 1080p60 screen share with click-to-watch and 540p cameras"`

---

### Task 11: Windows, Linux, iOS and Android builds

**Files:**
- Modify: platform folders under `app/` (permissions, entitlements, bundling the livekit binary on desktop)

**Interfaces:**
- Consumes: the whole app.
- Produces:
  - **Desktops:**
    - The Windows build bundles `vendor/livekit/windows-amd64/livekit-server.exe`, and the Linux build bundles `linux-amd64`.
    - Windows Firewall: on first host start, the app explains why it needs an inbound rule for UDP 7882 only.
  - **Phones:**
    - iOS and Android builds pass `can_host: false` and `livekit_bin: null`.
    - iOS: mic/camera usage strings and the `audio` background mode. A ReplayKit extension is not needed, because phones don't share.
    - Android: `RECORD_AUDIO`, `CAMERA`, `INTERNET`, and a foreground service of type `microphone` while in a call.
  - On phones the community file is imported from the share sheet or Files.

- [ ] **Step 1: Build each platform.**
  - Windows: run `flutter build windows` over SSH. Expected: success. This can take more than 4 minutes, so the main session runs it.
  - Linux: run `flutter build linux` on the ThinkPad.
  - iOS: run `flutter build ios`, then install it on the owner's iPhone and iPad with Xcode.
  - Android: run `flutter build apk`, then install it with `adb`.
- [ ] **Step 2: Run the manual check (owner present).** All five platforms join "lobby" with one shared community file. Phones hear and speak, and they can watch the Mac's screen share. Phones never show "you are host".
- [ ] **Step 3: Commit.** `git commit -am "feat(app): windows, linux, ios, android builds"`

---

### Task 12: `hubbub netcheck` (spike 2 tool)

**Files:**
- Create: `cli/src/netcheck.rs`
- Modify: `cli/src/main.rs`

**Interfaces:**
- Consumes: `Net`, `upnp::map_udp/unmap_udp`, `probe`.
- Produces:
  - Command: `hubbub netcheck [--community F --target <member-hex>] [--json]`.
  - `NetcheckReport` is serialized and has these fields:
    - `upnp: { ok: bool, external_ip: Option<String> }`. It maps UDP 47882 for 60 s and then unmaps it.
    - `iroh: { relay_url: Option<String>, direct_addrs: Vec<String>, symmetric_nat: Option<bool> }`, from iroh's net report.
    - `target: Option<{ kind: "direct"|"relay"|"none", rtt_ms: Option<u32>, upload_mbps: Option<u32> }>`
    - `os: String` and `at: String` (RFC 3339)
  - It prints a human summary unless `--json` is given.

- [ ] **Step 1: Write the failing test.** `netcheck_report_json_shape`: serialize a sample `NetcheckReport` and assert that the keys `upnp.ok`, `iroh.symmetric_nat`, `target.kind` and `os` are present.
- [ ] **Step 2: Run the test to see it fail.** Run `cargo test -p hubbub-cli netcheck`. Expected: FAIL.
- [ ] **Step 3: Implement** the command.
- [ ] **Step 4: Run the test and a real check.** Run `cargo test -p hubbub-cli netcheck && cargo run -p hubbub-cli -- netcheck --json`. Expected: PASS, then JSON from the Mac mini.
- [ ] **Step 5: Commit.** `git commit -am "feat(cli): netcheck for reachability field tests"`

---

### Task 13: Forced-relay media path (time-boxed: one working day)

This task answers the spec's open question: can media reach a host that no member can connect to directly, without leaving LiveKit?

**Files:**
- Create: `core/src/udp_relay.rs`, plus an "always relay" switch in `AppNodeConfig` (`force_relay: bool`)

**Interfaces:**
- Produces:
  - Approach A, to try first:
    - **Host side.** The host enables LiveKit's embedded TURN in UDP mode on `127.0.0.1:3478`.
    - **Member side.** Each member's core binds `127.0.0.1:3478/udp`. It forwards each datagram as an Iroh QUIC datagram on ALPN `hubbub/lk-turn/0` to the host's core, which relays it to the host's TURN port and back.
    - **Client side.** With `force_relay`, the client sets the ICE servers to `turn:127.0.0.1:3478?transport=udp`, using LiveKit-issued TURN credentials, and `iceTransportPolicy: relay`.
  - **Pass bar:** voice works between two machines with `force_relay` on, and measured `est_m2e_ms` stays under 150 ms on the LAN.

- [ ] **Step 1: Write the failing test.** `udp_relay_round_trips_datagrams`: an in-process UDP echo server sits behind a host `Net`, and a member's local UDP socket sends 100 datagrams and receives at least 95 back.
- [ ] **Step 2: Run the test to see it fail.** Run `cargo test -p hubbub-core udp_relay::`. Expected: FAIL.
- [ ] **Step 3: Implement** Approach A.
- [ ] **Step 4: Run the test and the manual check.** The test passes, then do the manual voice check with `force_relay` on.
  - If LiveKit's TURN config or credential flow blocks this within the time box, stop.
  - Record the exact blocker in the results doc, and record "forced-relay needs a custom forwarder (str0m/Pion)" as a finding. Do not start building that forwarder here.
- [ ] **Step 5: Commit.** `git commit -am "spike: forced-relay media path over iroh datagrams"` (or `docs: record forced-relay blocker`)

---

### Task 14: Measurement runs and the decision

**Files:**
- Create: `docs/spikes/spike-1-runbook.md`, `docs/spikes/spike-1-results.md`, `tools/summarize-metrics.py`

**Interfaces:**
- Consumes: the metrics JSONL from every device, and the netcheck JSON.
- Produces:
  - `tools/summarize-metrics.py <files...>` prints, per scenario tag:
    - p50 and p95 of `join.ms`, `stats.est_m2e_ms` and `handover.gap_ms`
    - received screen-share resolution and fps (p50 and p05)
    - sender `cpu.pct` p95
  - Run it with `python3 -I`, standard library only.

- [ ] **Step 1: Write the runbook.** It lists the scenarios, the owner's steps, and the file names to collect:
  - **S1 LAN voice:** the Mac mini, Windows PC and ThinkPad, plus the iPhone and Android on Wi-Fi.
  - **S2 Internet path:** S1 with the iPhone on mobile data.
  - **S3 Hand-over:** kill the host process 5 times and quit it gracefully 5 times.
  - **S4 Reference game night:** 5 participants.
    - The Windows PC shares a game at 1080p60, and the other 4 watch.
    - 3 cameras at 540p30. If there aren't enough people, use `lk load-test` bots on the host for the cameras.
    - Record the host's measured upload from `netcheck`.
  - **S5 CGNAT:** the ThinkPad on a phone hotspot, first as a member, then as the only desktop (it is forced to host).
  - **S6 Linux Wayland:** a screen share from the ThinkPad on Linux.
  - **S7 Forced relay:** S1 voice with `force_relay` on, if Task 13 passed.
  - **Friends' networks (spike 2):** each friend runs `hubbub netcheck --json` once against the owner's node, and the outputs are collected.
- [ ] **Step 2: Write `summarize-metrics.py`, with one doctest per statistic.** Run `python3 -I -m doctest tools/summarize-metrics.py`. Expected: no output (pass).
- [ ] **Step 3: Run the scenarios.**
  - The owner runs S1–S7 with the main session's help. Measurement runs go through the main session with `run_in_background`.
  - Collect the JSONL files into `docs/spikes/data/` (gitignored if larger than 5 MB in total, otherwise committed).
- [ ] **Step 4: Write `spike-1-results.md`.**
  - It has a table with one row per spec target and these columns: target, measured p50/p95, pass/fail. The targets:
    - voice join ≤ 1 s
    - mouth-to-ear < 150 ms
    - hand-over ≤ 5 s
    - 1080p60 to 4 viewers on a host with ≥ 40 Mbps upload
    - cameras at 540p30
    - cameras degrade before the share
  - Under that come the blockers found, the netcheck reachability summary (direct, UPnP and relay rates), and a **Decision** section. The decision is one of:
    1. Keep LiveKit-over-Iroh as the media stack.
    2. Keep LiveKit, but replace the forced-relay path.
    3. Replace LiveKit with a str0m- or Pion-based forwarder.

    The decision includes the measured reason.
  - If the hand-over p95 is over 5 s, use the host logs to say whether LiveKit's cold start dominates. That decides whether product plan B keeps a standby host warmed up.
- [ ] **Step 5: Commit.** `git add docs/spikes tools && git commit -m "docs: spike 1 results and media-stack decision"`

---

## After this plan

These are written once `spike-1-results.md` exists, each as its own plan:

1. **Spike 3: group keys and the signed admin log.** OpenMLS with members who are often offline, removals, late joiners, and the hash-chained ordering members cross-check (spec §4.1, §4.2, §5).
2. **Product plan A: identity, invites and text chat on desktop.** Real invites (§4.5), MLS replacing the spike key, the encrypted event log, and channels, messages and attachments.
3. **Product plan B: voice channels on the chosen media stack,** plus project-run relay and discovery replacing n0's.
4. **Product plan C: screen share and cameras hardening.**
5. **Product plan D: mobile clients and the push relay.**
