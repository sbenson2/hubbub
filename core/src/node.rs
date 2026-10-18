//! A running node: member sessions, the host election loop, the media host while elected,
//! and one local signal tunnel that always points at the current host.
//!
//! Tasks, all stopped when the `Node` is dropped:
//! - the election loop owns the `Election`, ticks every 100 ms and carries out its actions;
//! - the media actor owns the `MediaHost` and runs start, stop and mint strictly in order;
//! - the accept loop, one dialer per known peer (never phone to phone), and one task per
//!   control session, which closes it after 3 s of silence;
//! - the report loop and the local signal tunnel;
//! - on a host-capable node with relays, the background UPnP gateway search.
//!
//! They share `State` behind a std mutex that is never held across an await. Sessions feed
//! the election loop and the media actor through channels; each session has its own writer
//! task, so anything can queue a message to a peer without waiting.
use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use iroh::endpoint::{Connection, RecvStream, SendStream, VarInt};
use iroh::EndpointAddr;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout, MissedTickBehavior};

mod hosting;

use hosting::{gateway_loop, media_actor};

use crate::community::{CommunityState, NewMember};
use crate::election::{Action, Candidate, Election, HostState, Input, RankKey};
use crate::identity::Identity;
use crate::ids::MemberId;
use crate::media_host::MediaHost;
use crate::net::{ConnKind, Net, RelayChoice};
use crate::probe::{recv_probe, send_probe};
use crate::proto::{read_msg, write_msg, CtlMsg, PeerReport, ALPN_CTL, ALPN_LK_SIGNAL};
use crate::text::{Channels, Chat, Delivery, Ordered, Relay, Route, Submission, TextMessage};
use crate::tunnel::{serve_host, serve_local};
use crate::upnp::Gateway;
use crate::view::build_view;

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
const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
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
}

#[derive(Clone)]
pub struct VoiceCredentials {
    pub url: String,
    pub token: String,
    pub e2ee_key: [u8; 32],
    pub host: MemberId,
    pub term: u64,
}

pub struct Node {
    inner: Arc<Inner>,
    /// Dropping this stops every task: the hard-kill path, with no Resign.
    _stop: watch::Sender<()>,
}

impl Node {
    pub async fn start(cfg: NodeConfig, media: Box<dyn MediaHost>) -> Result<Node> {
        let community = CommunityState::load(&cfg.community_file)?;
        let peers = community
            .members
            .values()
            .map(|m| {
                let key = iroh::PublicKey::from_bytes(&m.id.0).context("invalid member id in community file")?;
                Ok(EndpointAddr::new(key))
            })
            .collect::<Result<Vec<_>>>()?;
        Self::launch(cfg, media, community, peers).await
    }

    /// Starts a node that dials only `peers`, at their given addresses (in-process tests).
    #[cfg(feature = "test-util")]
    pub async fn start_with_addrs(
        cfg: NodeConfig,
        media: Box<dyn MediaHost>,
        peers: Vec<EndpointAddr>,
    ) -> Result<Node> {
        let community = CommunityState::load(&cfg.community_file)?;
        Self::launch(cfg, media, community, peers).await
    }

    /// This node's loopback address, for `start_with_addrs` in tests.
    #[cfg(feature = "test-util")]
    pub async fn endpoint_addr(&self) -> Result<EndpointAddr> {
        self.inner.net.addr().await
    }

    async fn launch(
        cfg: NodeConfig,
        media: Box<dyn MediaHost>,
        community: CommunityState,
        peers: Vec<EndpointAddr>,
    ) -> Result<Node> {
        let identity = Identity::load_or_create(&cfg.data_dir)?;
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
        let net = Net::bind(&identity, community_rx, cfg.relay).await?;
        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.context("binding the local signal tunnel")?;
        let tunnel_port = listener.local_addr()?.port();
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
            upnp: uses_upnp(can_host, cfg.relay),
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
            state: Mutex::new(State {
                host: HostState { host: None, term: 0 },
                can_host,
                peers: HashMap::new(),
                reports: HashMap::new(),
                signal: None,
                lk_served: Vec::new(),
                lk_client: None,
                gateway: None,
            }),
            events,
            election,
            media: media_tx,
            stop,
            next_session: AtomicU64::new(0),
            upnp_warned: AtomicBool::new(false),
            chat,
            relay,
        });
        inner.spawn(election_loop(inner.clone(), election_rx));
        inner.spawn(media_actor(inner.clone(), media, media_rx));
        inner.spawn(accept_loop(inner.clone()));
        inner.spawn(report_loop(inner.clone()));
        inner.spawn(tunnel_loop(inner.clone(), listener));
        if inner.upnp {
            inner.spawn(gateway_loop(inner.clone()));
        }
        let initial: Vec<MemberId> = inner.dialing.lock().unwrap().iter().copied().collect();
        for peer in initial {
            inner.spawn(inner.clone().dial_loop(peer));
        }
        Ok(Node { inner, _stop: stop_tx })
    }

    pub fn member_id(&self) -> MemberId {
        self.inner.me
    }

    pub fn subscribe(&self) -> broadcast::Receiver<NodeEvent> {
        self.inner.events.subscribe()
    }

    pub fn host_state(&self) -> HostState {
        self.inner.state.lock().unwrap().host
    }

    pub fn channels(&self) -> Channels {
        self.inner.chat.channels().clone()
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
        self.inner.dial_addrs.lock().unwrap().insert(MemberId(*addr.id.as_bytes()), addr);
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
        let _ = timeout(CLOSE_TIMEOUT, inner.net.close()).await;
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
    /// Members' signal connections served while hosting; closed when hosting stops.
    lk_served: Vec<Connection>,
    /// This node's signal connection to the current host, reused across tunnel connections.
    lk_client: Option<(MemberId, Connection)>,
    /// The UPnP gateway found by the background search, while it keeps working.
    gateway: Option<Gateway>,
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
    /// Whether this node uses UPnP at all (see `uses_upnp`).
    upnp: bool,
    online_since_ms: u64,
    started: Instant,
    /// The live membership; `Net` holds a receiver. Replace it only through `apply_state`.
    community: watch::Sender<Arc<CommunityState>>,
    community_file: PathBuf,
    /// Held while the state is merged and saved: `save_atomic` uses one temp path.
    save_lock: Mutex<()>,
    identity: Identity,
    net: Net,
    /// Addresses to use for peers this node dials; others are dialed by id.
    dial_addrs: Mutex<HashMap<MemberId, EndpointAddr>>,
    /// Members that have a dial loop.
    dialing: Mutex<HashSet<MemberId>>,
    tunnel_port: u16,
    state: Mutex<State>,
    events: broadcast::Sender<NodeEvent>,
    election: mpsc::UnboundedSender<Cmd>,
    media: mpsc::UnboundedSender<MediaCmd>,
    stop: watch::Receiver<()>,
    next_session: AtomicU64,
    upnp_warned: AtomicBool,
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
        let st = self.state.lock().unwrap();
        for p in st.peers.values() {
            if let Some(s) = p.sessions.get(&p.newest) {
                let _ = s.out.send(Out::Msg(msg.clone()));
            }
        }
    }

    fn hello(&self, can_host: bool) -> CtlMsg {
        CtlMsg::Hello { member: self.me, can_host, online_since_ms: self.online_since_ms }
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
                    self.state.lock().unwrap().host = hs;
                    self.emit(NodeEvent::HostChanged {
                        host: hs.host,
                        term: hs.term,
                        is_me: hs.host == Some(self.me),
                    });
                    self.flush_text();
                }
            }
        }
    }

    async fn dial(&self, to: MemberId, alpn: &[u8]) -> Result<Connection> {
        let known = self.dial_addrs.lock().unwrap().get(&to).cloned();
        let addr = match known {
            Some(a) => a,
            // Not dialed at start (tests): iroh still knows the paths of a live connection.
            None => EndpointAddr::new(iroh::PublicKey::from_bytes(&to.0).context("invalid member id")?),
        };
        timeout(DIAL_TIMEOUT, self.net.connect_addr(addr, alpn)).await.context("connect timed out")?
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
            let established = match self.dial(peer, ALPN_CTL).await {
                Ok(conn) => self.clone().run_session(peer, conn, true).await,
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
            Some(CtlMsg::Hello { member, can_host, online_since_ms }) if member == peer => {
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
        ];
        let _ = self.read_loop(peer, id, &mut recv, &out, &pings, &heard_ms).await;
        for h in helpers {
            h.abort();
        }
        if self.remove_session(peer, id) {
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
        p.sessions.insert(id, Session { out, tokens: VecDeque::new() });
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
                CtlMsg::TextSubmit { channel, client_id, ciphertext } => {
                    self.relay_text(peer, Submission { channel, client_id, ciphertext }, Some(out))
                }
                CtlMsg::TextDeliver { channel, term, seq, from, client_id, sent_ms, ciphertext } => {
                    #[cfg(feature = "test-util")]
                    if self.chat.loses_delivery_from(&from) {
                        bail!("test: the session ends before this node reads its own delivery");
                    }
                    self.receive_text(&Delivery { channel, term, seq, from, client_id, sent_ms, ciphertext })
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
                    let c = self.dial(host, ALPN_LK_SIGNAL).await?;
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
            (Some(_), Some((session, out))) => self.chat.flush(Route::Remote { term, session }, |s| {
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
                self.broadcast(&d.to_msg());
                self.receive_text(&d);
            }
            (Ordered::Again(d), Some(out)) => {
                let _ = out.send(Out::Msg(d.to_msg()));
            }
            (Ordered::Again(d), None) => self.receive_text(&d),
        });
    }

    fn receive_text(&self, d: &Delivery) {
        self.chat.receive(d, |r| {
            let m = r.message;
            let (term, seq, from, sent_ms, body, client_id) = (m.term, m.seq, m.from, m.sent_ms, m.body, m.client_id);
            self.emit(NodeEvent::Text { channel: r.channel, term, seq, from, sent_ms, body, client_id });
        });
    }

    fn warn_upnp_once(&self, msg: &str) {
        if !self.upnp_warned.swap(true, Ordering::Relaxed) {
            eprintln!("hubbub node: {msg}");
        }
    }
}

/// One report per (reporter, member about), the latest, and only from reporters who are online.
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

/// Only a node that may host maps a port, and never without relays (tests stay hermetic).
fn uses_upnp(can_host: bool, relay: RelayChoice) -> bool {
    can_host && relay != RelayChoice::Disabled
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
        if alpn == ALPN_CTL {
            if both_phones(&inner.community(), &inner.me, &member) {
                conn.close(VarInt::from_u32(1), b"phones do not connect to each other");
                continue;
            }
            let session = inner.clone().run_session(member, conn, false);
            inner.spawn(async move {
                session.await;
            });
        } else if alpn == ALPN_LK_SIGNAL {
            inner.serve_signal(member, conn);
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

    #[test]
    fn upnp_only_for_host_capable_nodes_with_relays() {
        assert!(uses_upnp(true, RelayChoice::N0Default));
        assert!(!uses_upnp(false, RelayChoice::N0Default), "a member that never hosts never maps");
        assert!(!uses_upnp(true, RelayChoice::Disabled), "tests stay hermetic");
    }
}
