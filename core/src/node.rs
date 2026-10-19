//! A running node: member sessions, the host election loop, the media host while elected,
//! and one local signal tunnel that always points at the current host.
//!
//! Tasks, all stopped when the `Node` is dropped:
//! - the election loop owns the `Election`, ticks every 100 ms and carries out its actions;
//! - the media actor holds the node's lease on the shared media host and runs start, stop and mint strictly in order;
//! - the accept loop, one dialer per known peer (never phone to phone), and one task per
//!   control session, which closes it after 3 s of silence;
//! - the report loop and the local signal tunnel;
//!
//! They share `State` behind a std mutex that is never held across an await. Sessions feed
//! the election loop and the media actor through channels; each session has its own writer
//! task, so anything can queue a message to a peer without waiting.
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, ensure, Context, Result};
use iroh::endpoint::{Connection, RecvStream, SendStream, VarInt};
use iroh::EndpointAddr;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout, MissedTickBehavior};

mod hosting;
mod media_link;

use hosting::media_actor;

use crate::community::{CommunityState, NewMember};
use crate::election::{Action, Candidate, Election, HostState, Input, RankKey};
use crate::identity::Identity;
use crate::invite::Invite;
use crate::ids::{CommunityId, MemberId};
use crate::media_host::MediaHost;
use crate::media_shim::IceConfig;
use crate::media_tunnel::{serve_media_host, FlowLimits, MemberMedia, TunnelStats};
use crate::media_shared::SharedMedia;
use crate::net::{ConnKind, Net, RelayChoice, Switch};
use crate::probe::{recv_probe, send_probe};
use crate::join::JoinMsg;
use crate::proto::{read_json, read_msg, write_json, write_msg, CtlMsg, HaveChannel, PeerReport, VoicePresence, PROTO_VERSION};
use crate::text::{Channels, Chat, Delivery, Ordered, Relay, Route, Submission, TextMessage};
use crate::tunnel::{serve_host, serve_local};
use crate::view::build_view;
use crate::voice::{Slot, VoiceBook};

const TICK: Duration = Duration::from_millis(100);
const PING_EVERY: Duration = Duration::from_secs(1);
/// A peer silent this long (3 missed Pongs) is gone: its session is closed.
const SILENCE_LIMIT: Duration = Duration::from_secs(3);
const REPORT_EVERY: Duration = Duration::from_secs(2);
/// Weight of the newest sample in the RTT moving average.
const RTT_ALPHA: f64 = 0.3;
/// Pings awaiting a Pong; older ones are forgotten.
const PINGS_KEPT: usize = 8;
const DIAL_BACKOFF_MIN: Duration = Duration::from_secs(1);
const DIAL_BACKOFF_MAX: Duration = Duration::from_secs(10);
const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
/// A media dial is shorter: the TURN shim answers its clients one datagram at a time, so a slow
/// dial stalls every allocation behind it.
const MEDIA_DIAL_TIMEOUT: Duration = Duration::from_secs(3);
const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// How long live text waits for a peer's `TextHave` before it flows anyway.
const TEXT_HAVE_WAIT: Duration = Duration::from_secs(2);
/// A node whose media host failed to start stays out of the running this long.
const HOST_RETRY_AFTER: Duration = Duration::from_secs(60);
const TOKEN_TIMEOUT: Duration = Duration::from_secs(3);
/// How long `voice_credentials` keeps retrying while a host change settles.
const CREDENTIALS_WAIT: Duration = Duration::from_secs(8);
const FLUSH_TIMEOUT: Duration = Duration::from_millis(500);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(3);
/// Control messages go out before any other data queued on the connection, such as a probe.
const CTL_PRIORITY: i32 = i32::MAX;

pub struct NodeConfig {
    pub data_dir: PathBuf,
    pub community_file: PathBuf,
    pub can_host: bool,
    pub relay: RelayChoice,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "event")]
pub enum NodeEvent {
    HostChanged { host: Option<MemberId>, term: u64, is_me: bool },
    PeerUp { member: MemberId, kind: ConnKind },
    PeerDown { member: MemberId },
    /// A text message, opened: anyone's, this node's own included. One event per message,
    /// which `(from, client_id)` names; events come in arrival order, the order `text_history`
    /// keeps. `(term, seq)` is not an id: it changes when a message is resent after a hand-over.
    Text { channel: String, term: u64, seq: u64, from: MemberId, sent_ms: u64, body: String, client_id: u64 },
    /// The member list changed: someone joined, or a member's name or hosting ability did.
    /// `Node::members` has the new list. A change of who vouched for a member does not count.
    MembersChanged,
    /// Who is in which voice channel changed. The full list, not a change: replace what was
    /// shown. `Node::voice_roster` has the same list.
    VoiceRoster { entries: Vec<VoicePresence> },
}

#[derive(Clone)]
pub struct VoiceCredentials {
    pub url: String,
    pub token: String,
    pub e2ee_key: [u8; 32],
    pub host: MemberId,
    pub term: u64,
    /// The ICE server (this node's TURN shim) the LiveKit client must use, so its media
    /// goes through the tunnel. `None` if the machine has no usable address.
    pub ice: Option<IceConfig>,
}

/// A snapshot of the media tunnel's counters on one node.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MediaStats {
    /// Frames and payload bytes this node, as host or hosting its own client, sent to LiveKit.
    pub to_livekit_pkts: u64,
    pub to_livekit_bytes: u64,
    /// Frames and payload bytes LiveKit sent back.
    pub from_livekit_pkts: u64,
    pub from_livekit_bytes: u64,
    /// Frames and payload bytes that crossed the iroh connection.
    pub wire_tx_pkts: u64,
    pub wire_tx_bytes: u64,
    pub wire_rx_pkts: u64,
    pub wire_rx_bytes: u64,
    /// Frames dropped (queue full), sent on a uni stream (oversize), flow churn.
    pub dropped: u64,
    pub via_stream: u64,
    pub flows_opened: u64,
    pub flows_expired: u64,
    pub flows_refused: u64,
}

pub struct Node {
    inner: Arc<Inner>,
    /// Dropping this stops every task: the hard-kill path, with no Resign.
    _stop: watch::Sender<()>,
}

impl Node {
    pub async fn start(cfg: NodeConfig, media: Box<dyn MediaHost>) -> Result<Node> {
        let community = CommunityState::load(&cfg.community_file)?;
        let peers = listed_peers(&community)?;
        Self::launch(cfg, Media::Private(media), community, peers, None).await
    }

    /// Starts a node on a hub's shared endpoint, with the hub's identity. `cfg.data_dir` is
    /// this community's own folder (its text store); no identity is read from it.
    pub async fn start_in_hub(
        cfg: NodeConfig,
        media: Arc<SharedMedia>,
        switch: Arc<Switch>,
        identity: Arc<Identity>,
    ) -> Result<Node> {
        let community = CommunityState::load(&cfg.community_file)?;
        let peers = listed_peers(&community)?;
        Self::launch(cfg, Media::Shared(media), community, peers, Some((switch, identity))).await
    }

    /// Starts a node that dials only `peers`, at their given addresses (in-process tests).
    #[cfg(feature = "test-util")]
    pub async fn start_with_addrs(
        cfg: NodeConfig,
        media: Box<dyn MediaHost>,
        peers: Vec<EndpointAddr>,
    ) -> Result<Node> {
        let community = CommunityState::load(&cfg.community_file)?;
        Self::launch(cfg, Media::Private(media), community, peers, None).await
    }

    /// This node's loopback address, for `start_with_addrs` in tests.
    #[cfg(feature = "test-util")]
    pub async fn endpoint_addr(&self) -> Result<EndpointAddr> {
        self.inner.net.addr().await
    }

    async fn launch(
        cfg: NodeConfig,
        media: Media,
        community: CommunityState,
        peers: Vec<EndpointAddr>,
        shared: Option<(Arc<Switch>, Arc<Identity>)>,
    ) -> Result<Node> {
        let (switch, identity) = match shared {
            Some((switch, identity)) => (Some(switch), identity),
            None => (None, Arc::new(Identity::load_or_create(&cfg.data_dir)?)),
        };
        let me = identity.member_id();
        let entry = community.member(&me).with_context(|| format!("member {me} is not in the community file"))?;
        let can_host = cfg.can_host && entry.can_host;
        let dial_addrs: HashMap<MemberId, EndpointAddr> = peers
            .into_iter()
            .map(|a| (MemberId(*a.id.as_bytes()), a))
            .filter(|(m, _)| *m != me && community.is_member(m) && !both_phones(&community, &me, m))
            .collect();
        let (chat, relay) = (Chat::new(me, &community, &cfg.data_dir), Relay::new(&community.channels()));
        let (community_tx, community_rx) = watch::channel(Arc::new(community));
        let net = match switch {
            Some(switch) => switch.register(community_rx),
            None => Net::bind(&identity, community_rx, cfg.relay).await?,
        };
        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.context("binding the local signal tunnel")?;
        let tunnel_port = listener.local_addr()?.port();
        let media = match media {
            Media::Shared(m) => m,
            // Outside a hub the node has its own host.
            Media::Private(host) => Arc::new(SharedMedia::new(host)),
        };
        let (stop_tx, stop) = watch::channel(());
        let (events, _) = broadcast::channel(256);
        let (election, election_rx) = mpsc::unbounded_channel();
        let (media_tx, media_rx) = mpsc::unbounded_channel();
        let online_since_ms =
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
        let dialing = Mutex::new(dial_addrs.keys().copied().collect::<HashSet<_>>());
        let inner = Arc::new(Inner {
            me,
            can_host,
            online_since_ms,
            started: Instant::now(),
            community: community_tx,
            community_file: cfg.community_file,
            save_lock: Mutex::new(()),
            identity,
            net,
            dial_addrs: Mutex::new(dial_addrs),
            dialing,
            tunnel_port,
            shim: Mutex::new(None),
            media_stats: Arc::default(),
            media_members: Arc::default(),
            shim_gate: tokio::sync::Mutex::new(false),
            state: Mutex::new(State {
                host: HostState { host: None, term: 0 },
                can_host,
                peers: HashMap::new(),
                reports: HashMap::new(),
                signal: None,
                rtc: None,
                lk_served: Vec::new(),
                lk_client: None,
                voice: VoiceBook::default(),
            }),
            events,
            election,
            media: media_tx,
            stop,
            next_session: AtomicU64::new(0),
            chat,
            relay,
        });
        inner.spawn(election_loop(inner.clone(), election_rx));
        inner.spawn(media_actor(inner.clone(), media, media_rx));
        inner.spawn(accept_loop(inner.clone()));
        inner.spawn(report_loop(inner.clone()));
        inner.spawn(tunnel_loop(inner.clone(), listener));
        let initial: Vec<MemberId> = inner.dialing.lock().unwrap().iter().copied().collect();
        for peer in initial {
            inner.spawn(inner.clone().dial_loop(peer));
        }
        Ok(Node { inner, _stop: stop_tx })
    }

    pub fn member_id(&self) -> MemberId {
        self.inner.me
    }

    /// The server this node runs.
    pub fn community_id(&self) -> CommunityId {
        self.inner.community().id
    }

    pub fn subscribe(&self) -> broadcast::Receiver<NodeEvent> {
        self.inner.events.subscribe()
    }

    pub fn host_state(&self) -> HostState {
        self.inner.state.lock().unwrap().host
    }

    /// Tells every member where this node is in voice: `channel` is the voice channel it is
    /// in, or `None` when it is in none (an unknown channel counts as none).
    pub fn set_voice(&self, channel: Option<String>, muted: bool, deafened: bool) {
        let slot = self.inner.voice_slot(channel, muted, deafened);
        let msg = CtlMsg::VoiceState {
            channel: slot.as_ref().map(|s| s.channel.clone()),
            muted: slot.as_ref().is_some_and(|s| s.muted),
            deafened: slot.as_ref().is_some_and(|s| s.deafened),
        };
        {
            let mut st = self.inner.state.lock().unwrap();
            if st.voice.mine() == slot.as_ref() {
                return;
            }
            st.voice.set_mine(slot);
            Inner::broadcast_locked(&st, &msg);
        }
        self.inner.refresh_voice();
    }

    /// Who is in which voice channel, as this node shows it now.
    pub fn voice_roster(&self) -> Vec<VoicePresence> {
        self.inner.state.lock().unwrap().voice.shown().to_vec()
    }

    pub fn channels(&self) -> Channels {
        self.inner.chat.channels().clone()
    }

    /// The current community state, secret included (the door hands it to a new member).
    pub(crate) fn state(&self) -> Arc<CommunityState> {
        self.inner.community()
    }

    /// The server's name.
    pub fn community_name(&self) -> String {
        self.inner.community().name.clone()
    }

    /// Whether this node's member created the server.
    pub fn is_owner(&self) -> bool {
        self.inner.community().owner == self.inner.me
    }

    /// Signs an invite link to this server. `expires_in_min` and `max_uses` of 0 mean never
    /// and unlimited. Our own door goes first, then up to two other members' doors.
    pub fn invite_create(&self, expires_in_min: u32, max_uses: u8) -> String {
        let state = self.inner.community();
        let others: Vec<MemberId> =
            state.members.values().filter(|m| m.id != self.inner.me).map(|m| m.door).collect();
        Invite::create(&self.inner.identity, &state, expires_in_min, max_uses, &others).to_link()
    }

    /// Revokes the invite `link` for the whole server; every member learns of it.
    pub fn invite_revoke(&self, link: &str) -> Result<()> {
        let invite = Invite::parse(link)?;
        ensure!(invite.cid == self.community_id(), "that invite is for another server");
        let mut next = (*self.inner.community()).clone();
        next.revoke(invite.invite_id);
        self.inner.apply_state(&next)?;
        Ok(())
    }

    /// Every member of the community with its name, this node included.
    pub fn members(&self) -> Vec<(MemberId, String)> {
        self.inner.community().members.values().map(|m| (m.id, m.name.clone())).collect()
    }

    /// Admits `m`, signed by this node, and tells every connected peer; a loop dials the new
    /// member. Returns whether the member list changed (false if `m` was already a member).
    pub fn admit(&self, m: NewMember) -> Result<bool> {
        let mut next = (*self.inner.community()).clone();
        next.admit(&self.inner.identity, m)?;
        self.inner.apply_state(&next)
    }

    /// Where to dial `peer` when it is admitted or listed (in-process tests, which have no
    /// address lookup).
    #[cfg(feature = "test-util")]
    pub fn add_peer_addr(&self, addr: EndpointAddr) {
        let peer = MemberId(*addr.id.as_bytes());
        self.inner.dial_addrs.lock().unwrap().insert(peer, addr);
        // A peer learned late (tests) is dialed like one admitted late.
        if peer != self.inner.me && self.inner.dialing.lock().unwrap().insert(peer) {
            self.inner.spawn(self.inner.clone().dial_loop(peer));
        }
    }

    /// Sends `body` to text channel `channel` and returns its client id. Without a live host it
    /// waits in memory and goes out when one appears.
    pub async fn send_text(&self, channel: &str, body: &str) -> Result<u64> {
        let client_id = self.inner.chat.compose(channel, body)?;
        self.inner.flush_text();
        Ok(client_id)
    }

    /// Ends the session that brings this node's next own text delivery before reading it, as
    /// if the connection dropped just then (tests).
    #[cfg(feature = "test-util")]
    pub fn lose_next_own_text_delivery(&self) {
        self.inner.chat.lose_next_own_delivery();
    }

    /// The last `limit` messages stored for `channel`, in arrival order.
    pub fn text_history(&self, channel: &str, limit: usize) -> Result<Vec<TextMessage>> {
        self.inner.chat.history(channel, limit)
    }

    /// Counters of the media tunnel on this node: what it forwarded to LiveKit and got back
    /// (as host), and what crossed the iroh connection either way.
    pub fn media_stats(&self) -> MediaStats {
        let s = &self.inner.media_stats;
        let (to_livekit, from_livekit, wire_tx, wire_rx) = (s.up(), s.down(), s.wire_tx(), s.wire_rx());
        MediaStats {
            to_livekit_pkts: to_livekit.0,
            to_livekit_bytes: to_livekit.1,
            from_livekit_pkts: from_livekit.0,
            from_livekit_bytes: from_livekit.1,
            wire_tx_pkts: wire_tx.0,
            wire_tx_bytes: wire_tx.1,
            wire_rx_pkts: wire_rx.0,
            wire_rx_bytes: wire_rx.1,
            dropped: s.dropped.load(Ordering::Relaxed),
            via_stream: s.via_stream.load(Ordering::Relaxed),
            flows_opened: s.flows_opened.load(Ordering::Relaxed),
            flows_expired: s.flows_expired.load(Ordering::Relaxed),
            flows_refused: s.flows_refused.load(Ordering::Relaxed),
        }
    }

    /// Credentials for joining `room` on the current host. Retries for a few seconds while
    /// there is no host yet or the new host's media server is still starting.
    pub async fn voice_credentials(&self, room: &str) -> Result<VoiceCredentials> {
        let inner = &self.inner;
        let deadline = Instant::now() + CREDENTIALS_WAIT;
        loop {
            let hs = self.host_state();
            let attempt = match hs.host {
                None => Err(anyhow!("no host is elected")),
                Some(h) if h == inner.me => inner.mint_local(room).await.map(|(token, signal)| {
                    (h, format!("ws://127.0.0.1:{}", signal.port()), token)
                }),
                Some(h) => inner
                    .request_token(h, room)
                    .await
                    .map(|token| (h, format!("ws://127.0.0.1:{}", inner.tunnel_port), token)),
            };
            match attempt {
                Ok((host, url, token)) => {
                    return Ok(VoiceCredentials {
                        url,
                        token,
                        e2ee_key: inner.community().e2ee_key(),
                        host,
                        term: hs.term,
                        ice: inner.ice_config().await,
                    })
                }
                Err(e) if Instant::now() >= deadline => return Err(e),
                Err(_) => sleep(Duration::from_millis(200)).await,
            }
        }
    }

    /// Leaves gracefully: Resign if hosting, then stop the media host and remove the UPnP
    /// mapping, then close every connection.
    pub async fn shutdown(self) {
        self.shutdown_ref().await;
    }

    /// `shutdown` for a node that is shared (a hub's): the same graceful leave, and then
    /// every task is stopped even while other handles to the node remain. Closes only this
    /// node's connections, never a shared endpoint.
    pub async fn shutdown_ref(&self) {
        let inner = &self.inner;
        let (tx, rx) = oneshot::channel();
        if inner.election.send(Cmd::Shutdown(tx)).is_ok() {
            let _ = rx.await;
        }
        // The Resign is queued ahead of each Finish, so flushing delivers it.
        let flushed: Vec<oneshot::Receiver<()>> = {
            let st = inner.state.lock().unwrap();
            st.peers
                .values()
                .flat_map(|p| p.sessions.values())
                .filter_map(|s| {
                    let (tx, rx) = oneshot::channel();
                    s.out.send(Out::Finish(tx)).ok().map(|_| rx)
                })
                .collect()
        };
        let _ = timeout(FLUSH_TIMEOUT, async {
            for rx in flushed {
                let _ = rx.await;
            }
        })
        .await;
        let (tx, rx) = oneshot::channel();
        if inner.media.send(MediaCmd::Shutdown(tx)).is_ok() {
            let _ = rx.await;
        }
        // Leaving or stopping ends the TURN shim too: it dials the host on the (possibly
        // shared) endpoint, and nothing should be able to do that for a node that has left.
        // Holding the gate waits out a shim that is starting, and closing it stops the next.
        let mut closed = inner.shim_gate.lock().await;
        *closed = true;
        let shim = inner.shim.lock().unwrap().take();
        drop(closed);
        drop(shim);
        let _ = timeout(CLOSE_TIMEOUT, inner.net.close()).await;
        let _ = self._stop.send(());
    }
}

/// Outbound traffic for one control session's writer task.
enum Out {
    Msg(CtlMsg),
    /// Finish the stream, wait briefly for the peer to read all of it, then stop.
    Finish(oneshot::Sender<()>),
}

type OutTx = mpsc::UnboundedSender<Out>;
type TokenWaiter = oneshot::Sender<std::result::Result<String, String>>;
/// Pings sent and not yet answered: (nonce, sent at).
type Pings = Arc<Mutex<VecDeque<(u64, Instant)>>>;

struct Session {
    out: OutTx,
    /// The peer has said what text it holds (`TextHave`) and been caught up, so live
    /// deliveries may go to it: none overtakes the catch-up.
    text_ready: bool,
    /// A real `TextHave` was answered on this session. A second one is ignored, so a member
    /// cannot make the host queue the whole backlog again and again.
    text_have_answered: bool,
    /// TokenRequests sent on this session; the host answers them in order.
    tokens: VecDeque<TokenWaiter>,
}

/// A peer with at least one live control session (both sides may dial, so there can be two).
struct Peer {
    sessions: HashMap<u64, Session>,
    newest: u64,
    can_host: bool,
    online_since_ms: u64,
    rtt_ms: Option<f64>,
    /// This node's measurement of the peer's probe.
    upload_mbps: Option<u32>,
}

struct State {
    /// Mirror of the election state, updated on every `HostChanged`.
    host: HostState,
    /// Whether this node may host right now (false for a while after a failed start).
    can_host: bool,
    peers: HashMap<MemberId, Peer>,
    /// The latest Report from each reporter, this node included.
    reports: HashMap<MemberId, Vec<PeerReport>>,
    /// The media host's signal address while it runs.
    signal: Option<SocketAddr>,
    /// The media host's UDP address (loopback) while it runs: where members' media goes.
    rtc: Option<SocketAddr>,
    /// Members' signal connections served while hosting; closed when hosting stops.
    lk_served: Vec<Connection>,
    /// This node's signal connection to the current host, reused across tunnel connections.
    lk_client: Option<(MemberId, Connection)>,
    /// Who is in which voice channel (see `voice`).
    voice: VoiceBook,
}

enum Cmd {
    Input(Input),
    /// A control session finished its Hello exchange; `Out` reaches that session.
    SessionUp(OutTx),
    StartFailed { term: u64 },
    RestoreCanHost,
    Shutdown(oneshot::Sender<()>),
}

enum MintReply {
    Peer(OutTx),
    Local(oneshot::Sender<Result<(String, SocketAddr)>>),
}

enum MediaCmd {
    Start { term: u64 },
    Stop,
    Mint { member: MemberId, room: String, reply: MintReply },
    Shutdown(oneshot::Sender<()>),
}

struct Inner {
    me: MemberId,
    /// Configured ability to host (config and community entry).
    can_host: bool,
    online_since_ms: u64,
    started: Instant,
    /// The live membership; `Net` holds a receiver. Replace it only through `apply_state`.
    community: watch::Sender<Arc<CommunityState>>,
    community_file: PathBuf,
    /// Held while the state is merged and saved: `save_atomic` uses one temp path.
    save_lock: Mutex<()>,
    identity: Arc<Identity>,
    net: Net,
    /// Addresses to use for peers this node dials; others are dialed by id.
    dial_addrs: Mutex<HashMap<MemberId, EndpointAddr>>,
    /// Members that have a dial loop.
    dialing: Mutex<HashSet<MemberId>>,
    tunnel_port: u16,
    /// The TURN shim for call media, started with the first credentials.
    shim: Mutex<Option<media_link::ShimSlot>>,
    /// Counters of the media tunnel on this node (as host and as member).
    media_stats: Arc<TunnelStats>,
    /// Per-member flow budgets and connection counts for media connections served here.
    media_members: Arc<MemberMedia>,
    /// Serialises starting the shim. `true` once the node has shut down: no shim starts after.
    shim_gate: tokio::sync::Mutex<bool>,
    state: Mutex<State>,
    events: broadcast::Sender<NodeEvent>,
    election: mpsc::UnboundedSender<Cmd>,
    media: mpsc::UnboundedSender<MediaCmd>,
    stop: watch::Receiver<()>,
    next_session: AtomicU64,
    chat: Chat,
    /// Orders and passes on text messages while this node hosts.
    relay: Relay,
}

impl Inner {
    /// Spawns a task that ends when the node is dropped.
    fn spawn<F: Future<Output = ()> + Send + 'static>(&self, fut: F) -> JoinHandle<()> {
        let mut stop = self.stop.clone();
        tokio::spawn(async move {
            tokio::select! {
                _ = fut => {}
                _ = stop.changed() => {}
            }
        })
    }

    fn now_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    fn emit(&self, event: NodeEvent) {
        let _ = self.events.send(event);
    }

    fn elect(&self, input: Input) {
        let _ = self.election.send(Cmd::Input(input));
    }

    /// Queues `msg` on the newest session of every online peer.
    fn broadcast(&self, msg: &CtlMsg) {
        Self::broadcast_locked(&self.state.lock().unwrap(), msg);
    }

    fn broadcast_locked(st: &State, msg: &CtlMsg) {
        for p in st.peers.values() {
            if let Some(s) = p.sessions.get(&p.newest) {
                let _ = s.out.send(Out::Msg(msg.clone()));
            }
        }
    }

    /// Recomputes the voice roster. As host, sends a changed roster to every peer; if the
    /// roster this node shows changed, emits it. Call after anything that can change it.
    fn refresh_voice(&self) {
        let mut st = self.state.lock().unwrap();
        let host = st.host;
        let r = st.voice.refresh(self.me, host);
        if let Some((term, entries)) = r.broadcast {
            Self::broadcast_locked(&st, &CtlMsg::VoiceRoster { term, entries });
        }
        if let Some(entries) = r.shown {
            self.emit(NodeEvent::VoiceRoster { entries });
        }
    }

    /// The slot for a voice state, if `channel` is one of this community's voice channels.
    fn voice_slot(&self, channel: Option<String>, muted: bool, deafened: bool) -> Option<Slot> {
        let channel = channel?;
        self.chat.channels().voice.contains(&channel).then_some(Slot { channel, muted, deafened })
    }

    /// Like `broadcast`, to the peers whose newest session has been caught up on text.
    fn broadcast_text(&self, msg: &CtlMsg) {
        let st = self.state.lock().unwrap();
        for p in st.peers.values() {
            if let Some(s) = p.sessions.get(&p.newest).filter(|s| s.text_ready) {
                let _ = s.out.send(Out::Msg(msg.clone()));
            }
        }
    }

    /// Answers a peer's `TextHave`: sends the deliveries it lacks on `out`, then lets live
    /// ones follow. The relay's lock is held throughout, so no delivery slips in between.
    ///
    /// `peer_asked` is true for a `TextHave` from the peer: only the first one per session is
    /// answered. The fallback after `TEXT_HAVE_WAIT` (false) never counts as that answer.
    fn catch_up_text(
        &self,
        peer: MemberId,
        session: u64,
        out: &OutTx,
        since_ms: u64,
        have: &[HaveChannel],
        peer_asked: bool,
    ) {
        if peer_asked {
            let mut st = self.state.lock().unwrap();
            let Some(s) = st.peers.get_mut(&peer).and_then(|p| p.sessions.get_mut(&session)) else { return };
            if std::mem::replace(&mut s.text_have_answered, true) {
                return;
            }
        }
        self.relay.catch_up(since_ms, have, |missing| {
            missing.iter().for_each(|d| {
                let _ = out.send(Out::Msg(d.to_msg()));
            });
            let mut st = self.state.lock().unwrap();
            if let Some(s) = st.peers.get_mut(&peer).and_then(|p| p.sessions.get_mut(&session)) {
                s.text_ready = true;
            }
        });
    }

    fn hello(&self, can_host: bool) -> CtlMsg {
        CtlMsg::Hello { member: self.me, can_host, online_since_ms: self.online_since_ms, proto: PROTO_VERSION }
    }

    /// Records whether this node may host now and tells the peers with a fresh Hello.
    fn set_can_host(&self, can_host: bool) {
        self.state.lock().unwrap().can_host = can_host;
        self.broadcast(&self.hello(can_host));
    }

    fn listed_can_host(&self, m: &MemberId) -> bool {
        self.community().member(m).is_some_and(|e| e.can_host)
    }

    /// The current community state.
    fn community(&self) -> Arc<CommunityState> {
        self.community.borrow().clone()
    }

    /// Merges `other` into the live state. If anything changed: saves it, wakes the readers,
    /// starts dial loops for new members, sends the new state to every peer, and emits
    /// `MembersChanged` when the member list (ids, names, hosting ability) differs. Fails only
    /// when `other` belongs to another community; a failed save is logged and the state is
    /// still used.
    fn apply_state(self: &Arc<Self>, other: &CommunityState) -> Result<bool> {
        let (next, listed_before) = {
            let _saving = self.save_lock.lock().unwrap();
            let before = self.community();
            let mut next = (*before).clone();
            if !next.merge(other)? {
                return Ok(false);
            }
            if let Err(e) = next.save_atomic(&self.community_file) {
                eprintln!("hubbub: could not save {}: {e:#}", self.community_file.display());
            }
            self.community.send_replace(Arc::new(next.clone()));
            (next, before)
        };
        for m in next.members.keys() {
            if *m != self.me && !listed_before.is_member(m) && !both_phones(&next, &self.me, m) {
                if self.dialing.lock().unwrap().insert(*m) {
                    self.spawn(self.clone().dial_loop(*m));
                }
            }
        }
        self.broadcast(&CtlMsg::StateSync { state: next.public_view() });
        let listed = |s: &CommunityState| -> Vec<_> { s.members.values().map(|e| (e.id, e.name.clone(), e.can_host)).collect() };
        if listed(&listed_before) != listed(&next) {
            self.emit(NodeEvent::MembersChanged);
        }
        Ok(true)
    }

    /// With `HUBBUB_DEBUG_CTL=1`, logs one line about the session with `peer` to stderr, stamped
    /// with wall-clock time so two machines' logs line up. It times the startup probe, Pong RTTs
    /// and the gaps between heartbeats, to show whether bulk traffic delays control messages.
    fn debug(&self, peer: MemberId, what: std::fmt::Arguments<'_>) {
        static ON: OnceLock<bool> = OnceLock::new();
        if *ON.get_or_init(|| std::env::var_os("HUBBUB_DEBUG_CTL").is_some_and(|v| v != "0")) {
            let ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis());
            eprintln!("hubbub ctl-debug {}.{:03} {}<->{}: {what}", ms / 1000, ms % 1000, self.me.tag(), peer.tag());
        }
    }

    fn member_name(&self, m: &MemberId) -> String {
        self.community().member(m).map(|e| e.name.clone()).unwrap_or_default()
    }

    fn view(&self) -> Vec<Candidate> {
        let st = self.state.lock().unwrap();
        let mut online = vec![(self.me, st.can_host, self.online_since_ms)];
        online.extend(st.peers.iter().map(|(m, p)| (*m, p.can_host, p.online_since_ms)));
        build_view(&self.me, &online, &latest_reports(&st.reports, &online))
    }

    /// Carries out election actions.
    fn run(&self, actions: Vec<Action>, claim: &mut Option<(u64, RankKey)>) {
        for action in actions {
            match action {
                Action::StartHosting { term } => {
                    self.relay.start(term);
                    let _ = self.media.send(MediaCmd::Start { term });
                }
                Action::StopHosting => {
                    *claim = None;
                    self.relay.stop();
                    let _ = self.media.send(MediaCmd::Stop);
                }
                Action::SendHeartbeat { term, key } => {
                    *claim = Some((term, key));
                    self.broadcast(&CtlMsg::Heartbeat { term, key });
                }
                Action::SendAnnounce { term, key } => {
                    *claim = Some((term, key));
                    self.broadcast(&CtlMsg::Announce { term, key });
                }
                Action::HostChanged(hs) => {
                    let previous = std::mem::replace(&mut self.state.lock().unwrap().host, hs);
                    if previous.host != hs.host {
                        self.repoint_media();
                    }
                    self.emit(NodeEvent::HostChanged {
                        host: hs.host,
                        term: hs.term,
                        is_me: hs.host == Some(self.me),
                    });
                    self.flush_text();
                    self.refresh_voice();
                }
            }
        }
    }

    async fn dial(&self, to: MemberId, alpn: &[u8]) -> Result<Connection> {
        self.dial_within(to, alpn, DIAL_TIMEOUT).await
    }

    async fn dial_within(&self, to: MemberId, alpn: &[u8], limit: Duration) -> Result<Connection> {
        let known = self.dial_addrs.lock().unwrap().get(&to).cloned();
        let addr = match known {
            Some(a) => a,
            // Not dialed at start (tests): iroh still knows the paths of a live connection.
            None => EndpointAddr::new(iroh::PublicKey::from_bytes(&to.0).context("invalid member id")?),
        };
        timeout(limit, self.net.connect_addr(addr, alpn)).await.context("connect timed out")?
    }

    fn has_session(&self, peer: MemberId) -> bool {
        self.state.lock().unwrap().peers.contains_key(&peer)
    }

    /// Keeps a control session to `peer` up, unless the peer already dialed this node.
    async fn dial_loop(self: Arc<Self>, peer: MemberId) {
        let mut backoff = DIAL_BACKOFF_MIN;
        loop {
            while self.has_session(peer) {
                sleep(Duration::from_millis(250)).await;
            }
            let established = match self.dial(peer, self.net.ctl_alpn()).await {
                Ok(conn) => {
                    let ran = self.clone().run_session(peer, conn, true).await;
                    // Refused at the door of a member that has not heard of us (we were admitted
                    // while it was offline): show our signed entries, then dial again at once.
                    if !ran && self.rejoin(peer).await {
                        backoff = DIAL_BACKOFF_MIN;
                        continue;
                    }
                    ran
                }
                Err(_) => false,
            };
            // A session that ran resets the backoff; either way wait before redialing, so a
            // peer that just left is not dialed again while it closes.
            if established {
                backoff = DIAL_BACKOFF_MIN;
            }
            sleep(backoff).await;
            if !established {
                backoff = (backoff * 2).min(DIAL_BACKOFF_MAX);
            }
        }
    }

    /// Shows `peer` the chain of signed entries that proves this node is a member. Returns whether
    /// `peer` learned of us just now (and so will accept a control session).
    async fn rejoin(&self, peer: MemberId) -> bool {
        let chain = self.community().chain_for(&self.me);
        if chain.len() < 2 {
            return false; // the owner is known to everyone
        }
        let cid = self.community().id;
        let attempt = async {
            let conn = self.dial(peer, self.net.rejoin_alpn()).await?;
            let (mut send, mut recv) = conn.open_bi().await?;
            write_json(&mut send, &JoinMsg::Rejoin { cid, chain }).await?;
            let reply: Option<JoinMsg> = timeout(HELLO_TIMEOUT, read_json(&mut recv)).await.context("waiting for the reply")??;
            conn.close(VarInt::from_u32(0), b"done");
            anyhow::Ok(matches!(reply, Some(JoinMsg::RejoinOk { added: true })))
        };
        attempt.await.unwrap_or(false)
    }

    /// Answers a `Rejoin` from `who`, who may not be a member here yet. Its chain is merged like
    /// any other state, so only entries that verify against ours count.
    async fn serve_rejoin(self: Arc<Self>, who: MemberId, conn: Connection) {
        let work = async {
            let (mut send, mut recv) = conn.accept_bi().await?;
            let Some(JoinMsg::Rejoin { cid, chain }) = read_json(&mut recv).await? else { bail!("expected Rejoin") };
            let before = self.community();
            let reply = if cid != before.id {
                JoinMsg::RejoinRefused
            } else {
                let mut other = before.public_view();
                other.members = chain.into_iter().map(|e| (e.id, e)).collect();
                let added = self.apply_state(&other).unwrap_or(false) && !before.is_member(&who);
                if self.community().is_member(&who) {
                    JoinMsg::RejoinOk { added }
                } else {
                    JoinMsg::RejoinRefused
                }
            };
            write_json(&mut send, &reply).await?;
            let _ = send.finish();
            // Let the dialer read the reply before the connection goes.
            conn.closed().await;
            anyhow::Ok(())
        };
        let _ = timeout(HELLO_TIMEOUT, work).await;
        conn.close(VarInt::from_u32(0), b"done");
    }

    /// Runs one control session to its end; returns whether the Hello exchange completed.
    async fn run_session(self: Arc<Self>, peer: MemberId, conn: Connection, dialed: bool) -> bool {
        let established = match self.handshake(peer, &conn, dialed).await {
            Ok((send, recv, can_host, since)) => {
                self.serve_session(peer, &conn, send, recv, can_host, since).await;
                true
            }
            Err(_) => false,
        };
        conn.close(VarInt::from_u32(0), b"session over");
        established
    }

    async fn handshake(
        &self,
        peer: MemberId,
        conn: &Connection,
        dialed: bool,
    ) -> Result<(SendStream, RecvStream, bool, u64)> {
        let (mut send, mut recv) = if dialed {
            conn.open_bi().await?
        } else {
            timeout(HELLO_TIMEOUT, conn.accept_bi()).await.context("waiting for the control stream")??
        };
        send.set_priority(CTL_PRIORITY).context("setting control stream priority")?;
        let can_host = self.state.lock().unwrap().can_host;
        write_msg(&mut send, &self.hello(can_host)).await?;
        match timeout(HELLO_TIMEOUT, read_msg(&mut recv)).await.context("waiting for Hello")?? {
            Some(CtlMsg::Hello { member, can_host, online_since_ms, .. }) if member == peer => {
                Ok((send, recv, can_host && self.listed_can_host(&peer), online_since_ms))
            }
            other => bail!("expected Hello from {}, got {other:?}", peer.tag()),
        }
    }

    async fn serve_session(
        self: &Arc<Self>,
        peer: MemberId,
        conn: &Connection,
        send: SendStream,
        mut recv: RecvStream,
        can_host: bool,
        since: u64,
    ) {
        let id = self.next_session.fetch_add(1, Ordering::Relaxed);
        let (out, out_rx) = mpsc::unbounded_channel();
        let pings: Pings = Arc::default();
        let heard_ms = Arc::new(AtomicU64::new(self.now_ms()));
        if self.add_session(peer, id, out.clone(), can_host, since) {
            self.emit(NodeEvent::PeerUp { member: peer, kind: self.net.conn_kind(peer) });
        }
        let _ = out.send(Out::Msg(CtlMsg::StateSync { state: self.community().public_view() }));
        let _ = self.election.send(Cmd::SessionUp(out.clone()));
        // This may be a new session to the host.
        self.flush_text();
        // The peer, if it hosts, sends back what this node lacks (see `CtlMsg::TextHave`).
        let (since_ms, have) = self.chat.have();
        let _ = out.send(Out::Msg(CtlMsg::TextHave { since_ms, have }));
        {
            // Voice: this node's own state, and the roster if it hosts.
            let st = self.state.lock().unwrap();
            if let Some(s) = st.voice.mine() {
                let _ = out.send(Out::Msg(CtlMsg::VoiceState {
                    channel: Some(s.channel.clone()),
                    muted: s.muted,
                    deafened: s.deafened,
                }));
            }
            if let Some((term, entries)) = st.voice.roster_for_new_session(self.me, st.host) {
                let _ = out.send(Out::Msg(CtlMsg::VoiceRoster { term, entries }));
            }
        }
        let probe_conn = conn.clone();
        let prober = self.clone();
        let helpers = [
            self.spawn(write_loop(send, out_rx)),
            self.spawn(ping_loop(out.clone(), pings.clone())),
            self.spawn(async move {
                prober.debug(peer, format_args!("probe send start"));
                let t = Instant::now();
                let sent = send_probe(&probe_conn).await;
                prober.debug(peer, format_args!("probe send end after {} ms: {sent:?}", t.elapsed().as_millis()));
            }),
            self.spawn(self.clone().probe_loop(peer, conn.clone(), out.clone())),
            self.spawn(self.clone().silence_watch(conn.clone(), heard_ms.clone())),
            // A peer that sends no TextHave (a build that drops it) still gets live text.
            self.spawn({
                let (node, out) = (self.clone(), out.clone());
                async move {
                    sleep(TEXT_HAVE_WAIT).await;
                    node.catch_up_text(peer, id, &out, u64::MAX, &[], false);
                }
            }),
        ];
        let _ = self.read_loop(peer, id, &mut recv, &out, &pings, &heard_ms).await;
        for h in helpers {
            h.abort();
        }
        if self.remove_session(peer, id) {
            self.state.lock().unwrap().voice.peer_down(peer);
            self.refresh_voice();
            self.emit(NodeEvent::PeerDown { member: peer });
            self.elect(Input::PeerDown { member: peer, now_ms: self.now_ms() });
        }
    }

    /// Registers a session; true when it is the peer's first (the peer just came online).
    fn add_session(&self, peer: MemberId, id: u64, out: OutTx, can_host: bool, since: u64) -> bool {
        let mut st = self.state.lock().unwrap();
        let p = st.peers.entry(peer).or_insert_with(|| Peer {
            sessions: HashMap::new(),
            newest: id,
            can_host,
            online_since_ms: since,
            rtt_ms: None,
            upload_mbps: None,
        });
        let first = p.sessions.is_empty();
        p.sessions.insert(id, Session { out, text_ready: false, text_have_answered: false, tokens: VecDeque::new() });
        p.newest = id;
        p.can_host = can_host;
        p.online_since_ms = since;
        first
    }

    /// Drops a session; true when it was the peer's last (the peer went offline).
    fn remove_session(&self, peer: MemberId, id: u64) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(p) = st.peers.get_mut(&peer) else { return false };
        p.sessions.remove(&id);
        if let Some(&newest) = p.sessions.keys().max() {
            p.newest = newest;
            return false;
        }
        st.peers.remove(&peer);
        st.reports.remove(&peer);
        true
    }

    async fn read_loop(
        self: &Arc<Self>,
        peer: MemberId,
        id: u64,
        recv: &mut RecvStream,
        out: &OutTx,
        pings: &Pings,
        heard_ms: &AtomicU64,
    ) -> Result<()> {
        let mut last_heartbeat: Option<Instant> = None;
        while let Some(msg) = read_msg(recv).await? {
            heard_ms.store(self.now_ms(), Ordering::Relaxed);
            match msg {
                CtlMsg::Hello { member, can_host, .. } if member == peer => {
                    let can_host = can_host && self.listed_can_host(&peer);
                    if let Some(p) = self.state.lock().unwrap().peers.get_mut(&peer) {
                        p.can_host = can_host;
                    }
                }
                CtlMsg::Hello { .. } => bail!("Hello for another member from {}", peer.tag()),
                CtlMsg::StateSync { state } => {
                    // The connection was accepted from a member, but the list may have changed.
                    if self.community().is_member(&peer) {
                        if let Err(e) = self.apply_state(&state) {
                            eprintln!("hubbub: ignoring state from {}: {e:#}", peer.tag());
                        }
                    }
                }
                CtlMsg::Ping { nonce } => {
                    let _ = out.send(Out::Msg(CtlMsg::Pong { nonce }));
                }
                CtlMsg::Pong { nonce } => {
                    if let Some(rtt) = take_ping(pings, nonce) {
                        self.debug(peer, format_args!("pong rtt {} ms", rtt.as_millis()));
                        self.record_rtt(peer, rtt);
                    }
                }
                CtlMsg::Report { about } => {
                    self.state.lock().unwrap().reports.insert(peer, about);
                }
                CtlMsg::Heartbeat { term, key } => {
                    let gap = last_heartbeat.replace(Instant::now()).map(|t| t.elapsed().as_millis());
                    self.debug(peer, format_args!("heartbeat term {term}, gap {gap:?} ms"));
                    self.elect(Input::Heartbeat { from: peer, term, key, now_ms: self.now_ms() })
                }
                CtlMsg::Announce { term, key } => {
                    self.elect(Input::Announce { from: peer, term, key, now_ms: self.now_ms() })
                }
                CtlMsg::Resign { term } => self.elect(Input::Resign { from: peer, term, now_ms: self.now_ms() }),
                CtlMsg::TokenRequest { room } => {
                    let reply = MintReply::Peer(out.clone());
                    let _ = self.media.send(MediaCmd::Mint { member: peer, room, reply });
                }
                CtlMsg::TokenResponse { token } => self.answer_token(peer, id, Ok(token)),
                CtlMsg::TokenDenied { reason } => self.answer_token(peer, id, Err(reason)),
                // The peer's measurement of this node; the view uses other members' reports.
                CtlMsg::ProbeResult { .. } => {}
                CtlMsg::Unknown => {}
                CtlMsg::VoiceState { channel, muted, deafened } => {
                    let slot = self.voice_slot(channel, muted, deafened);
                    self.state.lock().unwrap().voice.set_peer(peer, slot);
                    self.refresh_voice();
                }
                CtlMsg::VoiceRoster { term, entries } => {
                    let known = self.chat.channels().voice.clone();
                    let entries = entries.into_iter().filter(|e| known.contains(&e.channel)).collect();
                    self.state.lock().unwrap().voice.offer(peer, term, entries);
                    self.refresh_voice();
                }
                CtlMsg::TextHave { since_ms, have } => self.catch_up_text(peer, id, &out, since_ms, &have, true),
                CtlMsg::TextSubmit { channel, client_id, ciphertext } => {
                    self.relay_text(peer, Submission { channel, client_id, ciphertext }, Some(out))
                }
                CtlMsg::TextDeliver { channel, term, seq, from, client_id, sent_ms, ciphertext } => {
                    #[cfg(feature = "test-util")]
                    if self.chat.loses_delivery_from(&from) {
                        bail!("test: the session ends before this node reads its own delivery");
                    }
                    self.receive_text(&Delivery { channel, term, seq, from, client_id, sent_ms, ciphertext }, peer)
                }
            }
        }
        Ok(())
    }

    fn record_rtt(&self, peer: MemberId, rtt: Duration) {
        let sample = rtt.as_secs_f64() * 1000.0;
        if let Some(p) = self.state.lock().unwrap().peers.get_mut(&peer) {
            p.rtt_ms = Some(match p.rtt_ms {
                None => sample,
                Some(avg) => RTT_ALPHA * sample + (1.0 - RTT_ALPHA) * avg,
            });
        }
    }

    /// Measures each probe the peer sends and answers with ProbeResult.
    async fn probe_loop(self: Arc<Self>, peer: MemberId, conn: Connection, out: OutTx) {
        while let Ok(stream) = conn.accept_uni().await {
            self.debug(peer, format_args!("probe recv start"));
            let t = Instant::now();
            let measured = recv_probe(stream).await;
            self.debug(peer, format_args!("probe recv end after {} ms: {measured:?} Mbps", t.elapsed().as_millis()));
            if let Ok(mbps) = measured {
                if let Some(p) = self.state.lock().unwrap().peers.get_mut(&peer) {
                    p.upload_mbps = Some(mbps);
                }
                let _ = out.send(Out::Msg(CtlMsg::ProbeResult { mbps }));
            }
        }
    }

    /// Closes a control session once the peer has been silent for longer than `SILENCE_LIMIT`.
    /// A member that vanished without a close (kill -9, power loss, a dropped network) then
    /// goes down the usual PeerDown path and leaves the view and this node's Reports.
    async fn silence_watch(self: Arc<Self>, conn: Connection, heard_ms: Arc<AtomicU64>) {
        let limit = SILENCE_LIMIT.as_millis() as u64;
        loop {
            let silent = self.now_ms().saturating_sub(heard_ms.load(Ordering::Relaxed));
            if silent > limit {
                conn.close(VarInt::from_u32(2), b"peer silent");
                return;
            }
            sleep(Duration::from_millis(limit - silent + 1)).await;
        }
    }

    fn answer_token(&self, peer: MemberId, id: u64, answer: std::result::Result<String, String>) {
        let mut st = self.state.lock().unwrap();
        let waiter = st.peers.get_mut(&peer).and_then(|p| p.sessions.get_mut(&id)).and_then(|s| s.tokens.pop_front());
        if let Some(w) = waiter {
            let _ = w.send(answer);
        }
    }

    /// Asks `host` for a token over its newest control session.
    async fn request_token(&self, host: MemberId, room: &str) -> Result<String> {
        let rx = {
            let mut st = self.state.lock().unwrap();
            let p = st.peers.get_mut(&host).context("not connected to the host")?;
            let newest = p.newest;
            let s = p.sessions.get_mut(&newest).context("not connected to the host")?;
            let (tx, rx) = oneshot::channel();
            s.out.send(Out::Msg(CtlMsg::TokenRequest { room: room.to_string() })).ok().context("session closed")?;
            s.tokens.push_back(tx);
            rx
        };
        match timeout(TOKEN_TIMEOUT, rx).await {
            Ok(Ok(Ok(token))) => Ok(token),
            Ok(Ok(Err(reason))) => bail!("host denied the token: {reason}"),
            Ok(Err(_)) => bail!("the session to the host ended"),
            Err(_) => bail!("token request timed out"),
        }
    }

    async fn mint_local(&self, room: &str) -> Result<(String, SocketAddr)> {
        let (tx, rx) = oneshot::channel();
        let cmd = MediaCmd::Mint { member: self.me, room: room.to_string(), reply: MintReply::Local(tx) };
        self.media.send(cmd).ok().context("media host stopped")?;
        rx.await.context("media host stopped")?
    }

    /// Serves a member's signal connection while this node's media host runs.
    fn serve_signal(self: &Arc<Self>, member: MemberId, conn: Connection) {
        let target = {
            let mut st = self.state.lock().unwrap();
            if st.signal.is_some() {
                st.lk_served.push(conn.clone());
            }
            st.signal
        };
        let Some(target) = target else {
            conn.close(VarInt::from_u32(1), b"not host");
            return;
        };
        let inner = self.clone();
        self.spawn(async move {
            // Ok or Err, the member's signal session is over either way.
            if let Err(e) = serve_host(conn.clone(), target).await {
                eprintln!("hubbub node: signal session from {} ended: {e:#}", member.tag());
            }
            inner.state.lock().unwrap().lk_served.retain(|c| c.stable_id() != conn.stable_id());
        });
    }

    /// Serves a member's media connection while this node's media host runs: its frames go to
    /// the host's loopback LiveKit. Only members reach this (`net` checks the ALPN's community).
    fn serve_media(self: &Arc<Self>, member: MemberId, conn: Connection) {
        let limits = FlowLimits::default();
        // The cap is per member, over all of its media connections here.
        let Some(permit) = self.media_members.admit(member, &limits) else {
            conn.close(VarInt::from_u32(2), b"too many media connections");
            return;
        };
        let target = {
            let mut st = self.state.lock().unwrap();
            if st.rtc.is_some() {
                st.lk_served.push(conn.clone());
            }
            st.rtc
        };
        let Some(target) = target else {
            conn.close(VarInt::from_u32(1), b"not host");
            return;
        };
        let inner = self.clone();
        self.spawn(async move {
            serve_media_host(conn.clone(), target, limits, permit.budget.clone(), inner.media_stats.clone()).await;
            drop(permit);
            inner.state.lock().unwrap().lk_served.retain(|c| c.stable_id() != conn.stable_id());
        });
    }

    /// Opens a signal stream to whoever hosts at call time, so a host change applies from
    /// the next tunnel connection.
    async fn open_signal(&self) -> Result<(SendStream, RecvStream)> {
        let host = self.state.lock().unwrap().host.host.context("no host is elected")?;
        if host == self.me {
            bail!("this node is the host; use its signal address directly");
        }
        for _ in 0..2 {
            let cached = {
                let st = self.state.lock().unwrap();
                st.lk_client
                    .as_ref()
                    .filter(|(h, c)| *h == host && c.close_reason().is_none())
                    .map(|(_, c)| c.clone())
            };
            let conn = match cached {
                Some(c) => c,
                None => {
                    let c = self.dial(host, self.net.sig_alpn()).await?;
                    self.state.lock().unwrap().lk_client = Some((host, c.clone()));
                    c
                }
            };
            match conn.open_bi().await {
                Ok(streams) => return Ok(streams),
                Err(_) => self.state.lock().unwrap().lk_client = None,
            }
        }
        bail!("could not open a signal stream to host {}", host.tag())
    }

    /// Submits the pending text messages not yet sent to the live host: in place while hosting,
    /// otherwise on the host's newest session. Without a live host they keep waiting.
    fn flush_text(&self) {
        let (host, session) = {
            let st = self.state.lock().unwrap();
            let p = st.host.host.and_then(|h| st.peers.get(&h));
            (st.host, p.and_then(|p| Some((p.newest, p.sessions.get(&p.newest)?.out.clone()))))
        };
        let term = host.term;
        match (host.host, session) {
            (Some(h), _) if h == self.me => {
                self.chat.flush(Route::Local { term }, |s| self.relay_text(self.me, s, None))
            }
            (Some(host), Some((session, out))) => self.chat.flush(Route::Remote { host, term, session }, |s| {
                let _ = out.send(Out::Msg(s.to_msg()));
            }),
            _ => {}
        }
    }

    /// While hosting: orders a message `from` submitted and delivers it to every member, this
    /// node included. A message sent again goes back only to its sender, on `reply`, the
    /// session it came on (None: this node). The relay passes ciphertext on; only
    /// `receive_text` opens it.
    fn relay_text(&self, from: MemberId, submission: Submission, reply: Option<&OutTx>) {
        self.relay.relay(from, submission, |ordered| match (ordered, reply) {
            (Ordered::New(d), _) => {
                self.broadcast_text(&d.to_msg());
                self.receive_text(&d, self.me);
            }
            (Ordered::Again(d), Some(out)) => {
                let _ = out.send(Out::Msg(d.to_msg()));
            }
            (Ordered::Again(d), None) => self.receive_text(&d, self.me),
        });
    }

    fn receive_text(&self, d: &Delivery, host: MemberId) {
        self.chat.receive(d, host, |r| {
            let m = r.message;
            let (term, seq, from, sent_ms, body, client_id) = (m.term, m.seq, m.from, m.sent_ms, m.body, m.client_id);
            self.emit(NodeEvent::Text { channel: r.channel, term, seq, from, sent_ms, body, client_id });
        });
    }
}

/// One report per (reporter, member about), the latest, and only from reporters who are online.
/// Every member of `community` as a peer to dial by id alone.
fn listed_peers(community: &CommunityState) -> Result<Vec<EndpointAddr>> {
    community
        .members
        .values()
        .map(|m| {
            let key = iroh::PublicKey::from_bytes(&m.id.0).context("invalid member id in community file")?;
            Ok(EndpointAddr::new(key))
        })
        .collect()
}

fn latest_reports(
    reports: &HashMap<MemberId, Vec<PeerReport>>,
    online: &[(MemberId, bool, u64)],
) -> HashMap<MemberId, Vec<PeerReport>> {
    reports
        .iter()
        .filter(|(reporter, _)| online.iter().any(|(m, _, _)| m == *reporter))
        .map(|(reporter, about)| {
            let mut seen = HashSet::new();
            let mut latest: Vec<PeerReport> = about.iter().rev().filter(|r| seen.insert(r.member)).cloned().collect();
            latest.reverse();
            (*reporter, latest)
        })
        .collect()
}

/// Two members listed as unable to host (phones) never connect to each other directly.
fn both_phones(community: &CommunityState, a: &MemberId, b: &MemberId) -> bool {
    let listed_can_host = |m: &MemberId| community.member(m).is_some_and(|e| e.can_host);
    !listed_can_host(a) && !listed_can_host(b)
}

/// Where a node's media host comes from.
enum Media {
    /// A hub's, shared by all its servers.
    Shared(Arc<SharedMedia>),
    /// A node outside a hub gets a host of its own.
    Private(Box<dyn MediaHost>),
}

fn take_ping(pings: &Pings, nonce: u64) -> Option<Duration> {
    let mut p = pings.lock().unwrap();
    let i = p.iter().position(|(n, _)| *n == nonce)?;
    p.remove(i).map(|(_, sent)| sent.elapsed())
}

async fn write_loop(mut send: SendStream, mut rx: mpsc::UnboundedReceiver<Out>) {
    while let Some(out) = rx.recv().await {
        match out {
            Out::Msg(m) => {
                if write_msg(&mut send, &m).await.is_err() {
                    return;
                }
            }
            Out::Finish(done) => {
                let _ = send.finish();
                let _ = timeout(FLUSH_TIMEOUT, send.stopped()).await;
                let _ = done.send(());
                return;
            }
        }
    }
}

async fn ping_loop(out: OutTx, pings: Pings) {
    let mut every = tokio::time::interval(PING_EVERY);
    let mut nonce: u64 = 0;
    loop {
        every.tick().await;
        nonce += 1;
        {
            let mut p = pings.lock().unwrap();
            p.push_back((nonce, Instant::now()));
            if p.len() > PINGS_KEPT {
                p.pop_front();
            }
        }
        if out.send(Out::Msg(CtlMsg::Ping { nonce })).is_err() {
            return;
        }
    }
}

async fn accept_loop(inner: Arc<Inner>) {
    while let Some((member, alpn, conn)) = inner.net.accept().await {
        if alpn == inner.net.ctl_alpn() {
            if both_phones(&inner.community(), &inner.me, &member) {
                conn.close(VarInt::from_u32(1), b"phones do not connect to each other");
                continue;
            }
            let session = inner.clone().run_session(member, conn, false);
            inner.spawn(async move {
                session.await;
            });
        } else if alpn == inner.net.sig_alpn() {
            inner.serve_signal(member, conn);
        } else if alpn == inner.net.media_alpn() {
            inner.serve_media(member, conn);
        } else if alpn == inner.net.rejoin_alpn() {
            let node = inner.clone();
            inner.spawn(node.serve_rejoin(member, conn));
        }
    }
}

/// Every 2 s (first after 1 s), report what this node measured about its peers.
async fn report_loop(inner: Arc<Inner>) {
    let first = tokio::time::Instant::now() + Duration::from_secs(1);
    let mut every = tokio::time::interval_at(first, REPORT_EVERY);
    loop {
        every.tick().await;
        let about: Vec<PeerReport> = {
            let st = inner.state.lock().unwrap();
            st.peers
                .iter()
                .filter_map(|(m, p)| {
                    Some(PeerReport {
                        member: *m,
                        rtt_ms: p.rtt_ms?.round() as u32,
                        direct: inner.net.conn_kind(*m) == ConnKind::Direct,
                        upload_mbps: p.upload_mbps,
                    })
                })
                .collect()
        };
        inner.state.lock().unwrap().reports.insert(inner.me, about.clone());
        inner.broadcast(&CtlMsg::Report { about });
    }
}

/// Serves the local signal tunnel, restarting it on the same port if it ever stops.
async fn tunnel_loop(inner: Arc<Inner>, mut listener: TcpListener) {
    let port = inner.tunnel_port;
    loop {
        let open_inner = inner.clone();
        let open = move || {
            let inner = open_inner.clone();
            async move { inner.open_signal().await }
        };
        if let Err(e) = serve_local(listener, open).await {
            eprintln!("hubbub node: signal tunnel stopped ({e:#}); restarting on port {port}");
        }
        listener = loop {
            sleep(Duration::from_secs(1)).await;
            match TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await {
                Ok(l) => break l,
                Err(e) => eprintln!("hubbub node: rebinding signal tunnel port {port}: {e}"),
            }
        };
    }
}

async fn election_loop(inner: Arc<Inner>, mut rx: mpsc::UnboundedReceiver<Cmd>) {
    let me = inner.me;
    let mut election = Election::new(me, inner.can_host, 0);
    // This node's current claim, for an immediate heartbeat to a peer whose session (re)starts.
    let mut claim: Option<(u64, RankKey)> = None;
    let mut tick = tokio::time::interval(TICK);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        let input = tokio::select! {
            _ = tick.tick() => Input::Tick { now_ms: inner.now_ms() },
            cmd = rx.recv() => match cmd {
                None => return,
                Some(Cmd::Input(input)) => input,
                Some(Cmd::SessionUp(out)) => {
                    let hs = *election.state();
                    if let Some((term, key)) = claim.filter(|(t, _)| hs.host == Some(me) && *t == hs.term) {
                        let _ = out.send(Out::Msg(CtlMsg::Heartbeat { term, key }));
                    }
                    continue;
                }
                Some(Cmd::StartFailed { term }) => {
                    if *election.state() != (HostState { host: Some(me), term }) {
                        continue;
                    }
                    let view = inner.view();
                    let actions = election.step(Input::SelfResign { now_ms: inner.now_ms() }, &view);
                    inner.run(actions, &mut claim);
                    inner.broadcast(&CtlMsg::Resign { term });
                    election.set_can_host(false);
                    inner.set_can_host(false);
                    let retry = inner.election.clone();
                    inner.spawn(async move {
                        sleep(HOST_RETRY_AFTER).await;
                        let _ = retry.send(Cmd::RestoreCanHost);
                    });
                    continue;
                }
                Some(Cmd::RestoreCanHost) => {
                    election.set_can_host(inner.can_host);
                    inner.set_can_host(inner.can_host);
                    continue;
                }
                Some(Cmd::Shutdown(done)) => {
                    let hs = *election.state();
                    if hs.host == Some(me) {
                        inner.broadcast(&CtlMsg::Resign { term: hs.term });
                    }
                    let _ = done.send(());
                    return;
                }
            },
        };
        let view = inner.view();
        let actions = election.step(input, &view);
        inner.run(actions, &mut claim);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(b: u8) -> MemberId {
        MemberId([b; 32])
    }

    fn report(member: MemberId, rtt_ms: u32) -> PeerReport {
        PeerReport { member, rtt_ms, direct: true, upload_mbps: None }
    }

    #[test]
    fn latest_reports_keeps_one_entry_per_member_from_online_reporters() {
        let (a, b, c, gone) = (id(1), id(2), id(3), id(9));
        let mut reports = HashMap::new();
        reports.insert(a, vec![report(b, 50), report(c, 7), report(b, 20)]);
        reports.insert(gone, vec![report(b, 1)]);
        let online = [(a, true, 0), (b, true, 0), (c, true, 0)];
        let latest = latest_reports(&reports, &online);
        assert_eq!(latest.len(), 1, "reports from offline reporters are dropped");
        assert_eq!(latest[&a], vec![report(c, 7), report(b, 20)]);
    }
}
