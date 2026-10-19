//! Call media through the iroh connection.
//!
//! LiveKit listens on loopback only (so the host opens no firewall port), which means a
//! remote member cannot send it UDP. Instead its media rides QUIC datagrams on the member's
//! `media_alpn` connection to the host: each datagram is `[flow id u16 BE][payload]`. The host
//! gives every flow its own UDP socket toward LiveKit and sends LiveKit's replies back on the
//! same flow. A datagram that does not fit the path's datagram limit goes on a one-shot uni
//! stream with the same framing, so nothing is lost to a small MTU.
//!
//! This file is the transport: framing, the host-side forwarder and the iroh link. The
//! member-side TURN server that feeds it is `media_shim`.
//!
//! Admission: the connection arrives on the community's `media_alpn`, which `net` accepts only
//! from current members. A flow can only reach `target`, the host's own LiveKit UDP port:
//! the addresses a TURN client names are never used.
use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use iroh::endpoint::Connection;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::ids::MemberId;

/// Bytes of flow id in front of each payload.
pub const FLOW_HEADER: usize = 2;
/// Largest frame accepted on a uni stream (a UDP datagram is at most 64 KiB).
const MAX_STREAM_FRAME: usize = 65_600;
/// Oversize frames in flight at once; more are dropped, as a full datagram queue would.
const MAX_STREAM_SENDS: usize = 64;
/// Largest UDP payload read from LiveKit.
const UDP_BUF: usize = 65_536;

/// `[flow][payload]`.
pub fn encode_frame(flow: u16, payload: &[u8]) -> Bytes {
    let mut v = Vec::with_capacity(FLOW_HEADER + payload.len());
    v.extend_from_slice(&flow.to_be_bytes());
    v.extend_from_slice(payload);
    Bytes::from(v)
}

/// Splits a frame into its flow and payload; `None` if it is too short to hold a flow id.
pub fn decode_frame(frame: &[u8]) -> Option<(u16, &[u8])> {
    let (head, payload) = frame.split_at_checked(FLOW_HEADER)?;
    Some((u16::from_be_bytes([head[0], head[1]]), payload))
}

/// Where frames go. Sending never blocks and never fails loudly: media is real-time, so a
/// frame that cannot go now is dropped and counted.
pub trait FrameSink: Send + Sync {
    fn send_frame(&self, flow: u16, payload: &[u8]);

    /// The flow is over; the far end may drop its state at once. Best effort (a lost close
    /// is covered by the host's idle expiry).
    fn close_flow(&self, _flow: u16) {}
}

/// Counters for one tunnel end; also the evidence behind the tests.
#[derive(Default)]
pub struct TunnelStats {
    /// Frames and payload bytes sent toward LiveKit (host) or the host (member).
    pub up_pkts: AtomicU64,
    pub up_bytes: AtomicU64,
    /// Frames and payload bytes coming back.
    pub down_pkts: AtomicU64,
    pub down_bytes: AtomicU64,
    /// Frames dropped because the send queue was full or the path refused them.
    pub dropped: AtomicU64,
    /// Frames that went on a uni stream because they exceeded the datagram limit.
    pub via_stream: AtomicU64,
    /// Frames and payload bytes that crossed the iroh connection, sent and received, whichever
    /// role this node plays (member to host, or host to member).
    pub wire_tx_pkts: AtomicU64,
    pub wire_tx_bytes: AtomicU64,
    pub wire_rx_pkts: AtomicU64,
    pub wire_rx_bytes: AtomicU64,
    pub flows_opened: AtomicU64,
    pub flows_expired: AtomicU64,
    /// New flows refused because the member already holds the maximum.
    pub flows_refused: AtomicU64,
}

impl TunnelStats {
    pub fn up(&self) -> (u64, u64) {
        (self.up_pkts.load(Relaxed), self.up_bytes.load(Relaxed))
    }
    pub fn down(&self) -> (u64, u64) {
        (self.down_pkts.load(Relaxed), self.down_bytes.load(Relaxed))
    }
    pub fn wire_tx(&self) -> (u64, u64) {
        (self.wire_tx_pkts.load(Relaxed), self.wire_tx_bytes.load(Relaxed))
    }
    pub fn wire_rx(&self) -> (u64, u64) {
        (self.wire_rx_pkts.load(Relaxed), self.wire_rx_bytes.load(Relaxed))
    }
}

/// Host-side limits on one member's flows.
#[derive(Clone, Copy, Debug)]
pub struct FlowLimits {
    pub max_flows: usize,
    /// A flow with no traffic either way for this long is closed.
    pub idle: Duration,
}

impl Default for FlowLimits {
    fn default() -> Self {
        // A call holds two flows (publish and subscribe peer connections); the rest is
        // headroom for ICE restarts. ICE keep-alives arrive every few seconds.
        FlowLimits { max_flows: 16, idle: Duration::from_secs(30) }
    }
}

/// How many flows one member may hold on this host, across all of its media connections.
pub struct FlowBudget {
    used: AtomicUsize,
    max: usize,
}

impl FlowBudget {
    pub fn new(max: usize) -> Arc<FlowBudget> {
        Arc::new(FlowBudget { used: AtomicUsize::new(0), max })
    }

    fn take(&self) -> bool {
        self.used.try_update(Relaxed, Relaxed, |u| (u < self.max).then_some(u + 1)).is_ok()
    }

    fn release(&self) {
        self.used.fetch_sub(1, Relaxed);
    }

    /// Flows held now.
    pub fn used(&self) -> usize {
        self.used.load(Relaxed)
    }
}

/// Media connections one member may hold on this host at once (a call needs one; the rest
/// is headroom for a reconnect that overlaps the old connection's close).
pub const MAX_MEDIA_CONNS: usize = 4;

/// The host's per-member view of media: each member's flow budget and connection count.
#[derive(Default)]
pub struct MemberMedia {
    slots: Mutex<HashMap<MemberId, (Arc<FlowBudget>, usize)>>,
}

/// One admitted media connection; dropping it frees the member's connection slot.
pub struct MediaPermit {
    owner: Arc<MemberMedia>,
    member: MemberId,
    /// The member's flow budget, shared by all of its connections.
    pub budget: Arc<FlowBudget>,
}

impl MemberMedia {
    /// Admits a new media connection from `member`, or `None` if it already holds
    /// [`MAX_MEDIA_CONNS`].
    pub fn admit(self: &Arc<Self>, member: MemberId, limits: &FlowLimits) -> Option<MediaPermit> {
        let mut slots = self.slots.lock().unwrap();
        let slot = slots.entry(member).or_insert_with(|| (FlowBudget::new(limits.max_flows), 0));
        if slot.1 >= MAX_MEDIA_CONNS {
            return None;
        }
        slot.1 += 1;
        Some(MediaPermit { owner: self.clone(), member, budget: slot.0.clone() })
    }

    /// Members with a media connection now.
    pub fn members(&self) -> usize {
        self.slots.lock().unwrap().len()
    }
}

impl Drop for MediaPermit {
    fn drop(&mut self) {
        let mut slots = self.owner.slots.lock().unwrap();
        if let Some(slot) = slots.get_mut(&self.member) {
            slot.1 -= 1;
            if slot.1 == 0 {
                slots.remove(&self.member);
            }
        }
    }
}

struct Flow {
    /// Used to send; a std socket, because a tokio one refuses its first sends until the
    /// reactor has registered it.
    send: std::net::UdpSocket,
    /// Milliseconds since the table started, of the last frame in either direction.
    last_ms: Arc<AtomicU64>,
    reader: JoinHandle<()>,
    /// Holds one unit of the member's budget until the flow is dropped.
    budget: Arc<FlowBudget>,
}

impl Drop for Flow {
    fn drop(&mut self) {
        self.reader.abort();
        self.budget.release();
    }
}

struct Table {
    target: SocketAddr,
    reply: Arc<dyn FrameSink>,
    limits: FlowLimits,
    budget: Arc<FlowBudget>,
    epoch: Instant,
    flows: Mutex<HashMap<u16, Flow>>,
    stats: Arc<TunnelStats>,
}

/// The host-side forwarder for one member: frames in become UDP to `target` on a socket of
/// their own per flow; UDP coming back goes out through `reply` as frames on the same flow.
/// Flows open on their first frame, expire when idle (or when the far end closes them) and are
/// capped by a [`FlowBudget`].
pub struct FlowTable {
    table: Arc<Table>,
    reaper: JoinHandle<()>,
}

impl Drop for FlowTable {
    fn drop(&mut self) {
        self.reaper.abort();
        self.table.flows.lock().unwrap().clear();
    }
}

impl FlowTable {
    /// Must run inside a tokio runtime.
    pub fn new(target: SocketAddr, reply: Arc<dyn FrameSink>, limits: FlowLimits, stats: Arc<TunnelStats>) -> FlowTable {
        FlowTable::with_budget(target, reply, limits, FlowBudget::new(limits.max_flows), stats)
    }

    /// As [`FlowTable::new`], with the flow cap drawn from `budget`, which a member's several
    /// connections share.
    pub fn with_budget(
        target: SocketAddr,
        reply: Arc<dyn FrameSink>,
        limits: FlowLimits,
        budget: Arc<FlowBudget>,
        stats: Arc<TunnelStats>,
    ) -> FlowTable {
        let table = Arc::new(Table {
            target,
            reply,
            limits,
            budget,
            epoch: Instant::now(),
            flows: Mutex::new(HashMap::new()),
            stats,
        });
        let weak = Arc::downgrade(&table);
        let every = (limits.idle / 4).max(Duration::from_millis(10));
        let reaper = tokio::spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                let Some(t) = weak.upgrade() else { return };
                t.expire();
            }
        });
        FlowTable { table, reaper }
    }

    /// Flows currently open.
    pub fn flows(&self) -> usize {
        self.table.flows.lock().unwrap().len()
    }
}

impl FrameSink for FlowTable {
    /// A frame toward LiveKit.
    fn send_frame(&self, flow: u16, payload: &[u8]) {
        if payload.is_empty() {
            // A header-only frame is the far end closing the flow.
            self.close_flow(flow);
        } else {
            self.table.forward(flow, payload);
        }
    }

    fn close_flow(&self, flow: u16) {
        self.table.flows.lock().unwrap().remove(&flow);
    }
}

impl Table {
    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    fn forward(self: &Arc<Self>, flow: u16, payload: &[u8]) {
        let mut flows = self.flows.lock().unwrap();
        if !flows.contains_key(&flow) {
            if !self.budget.take() {
                self.stats.flows_refused.fetch_add(1, Relaxed);
                return;
            }
            match self.open(flow) {
                Ok(f) => {
                    flows.insert(flow, f);
                    self.stats.flows_opened.fetch_add(1, Relaxed);
                }
                Err(e) => {
                    self.budget.release();
                    eprintln!("hubbub media: opening flow {flow} toward {} failed: {e}", self.target);
                    return;
                }
            }
        }
        let f = &flows[&flow];
        f.last_ms.store(self.now_ms(), Relaxed);
        match f.send.send(payload) {
            Ok(_) => {
                self.stats.up_pkts.fetch_add(1, Relaxed);
                self.stats.up_bytes.fetch_add(payload.len() as u64, Relaxed);
            }
            Err(_) => {
                self.stats.dropped.fetch_add(1, Relaxed);
            }
        }
    }

    fn open(self: &Arc<Self>, flow: u16) -> std::io::Result<Flow> {
        let local: SocketAddr = match self.target {
            SocketAddr::V4(_) => (Ipv4Addr::LOCALHOST, 0).into(),
            SocketAddr::V6(_) => (Ipv6Addr::LOCALHOST, 0).into(),
        };
        let std_sock = std::net::UdpSocket::bind(local)?;
        std_sock.connect(self.target)?;
        std_sock.set_nonblocking(true)?;
        let sock = UdpSocket::from_std(std_sock.try_clone()?)?;
        let last_ms = Arc::new(AtomicU64::new(self.now_ms()));
        let reader = {
            let (reply, stats, last) = (self.reply.clone(), self.stats.clone(), last_ms.clone());
            let epoch = self.epoch;
            tokio::spawn(async move {
                let mut buf = vec![0u8; UDP_BUF];
                loop {
                    match sock.recv(&mut buf).await {
                        Ok(n) => {
                            last.store(epoch.elapsed().as_millis() as u64, Relaxed);
                            if n == 0 {
                                continue; // an empty frame would read as a close
                            }
                            stats.down_pkts.fetch_add(1, Relaxed);
                            stats.down_bytes.fetch_add(n as u64, Relaxed);
                            reply.send_frame(flow, &buf[..n]);
                        }
                        // Windows reports an ICMP port-unreachable (LiveKit not listening yet,
                        // or just gone) as a receive error on the socket; the flow carries on.
                        Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => continue,
                        Err(_) => return,
                    }
                }
            })
        };
        Ok(Flow { send: std_sock, last_ms, reader, budget: self.budget.clone() })
    }

    fn expire(&self) {
        let now = self.now_ms();
        let idle = self.limits.idle.as_millis() as u64;
        let mut flows = self.flows.lock().unwrap();
        let before = flows.len();
        flows.retain(|_, f| now.saturating_sub(f.last_ms.load(Relaxed)) < idle);
        self.stats.flows_expired.fetch_add((before - flows.len()) as u64, Relaxed);
    }
}

/// Delivers frames to local receivers by flow: the member side, where each TURN allocation
/// owns one flow.
#[derive(Clone, Default)]
pub struct Routes {
    map: Arc<Mutex<HashMap<u16, mpsc::Sender<Bytes>>>>,
}

impl Routes {
    pub fn open(&self, flow: u16) -> mpsc::Receiver<Bytes> {
        let (tx, rx) = mpsc::channel(512);
        self.map.lock().unwrap().insert(flow, tx);
        rx
    }

    pub fn close(&self, flow: u16) {
        self.map.lock().unwrap().remove(&flow);
    }

    pub fn contains(&self, flow: u16) -> bool {
        self.map.lock().unwrap().contains_key(&flow)
    }

    pub fn clear(&self) {
        self.map.lock().unwrap().clear();
    }

    pub fn len(&self) -> usize {
        self.map.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl FrameSink for Routes {
    fn send_frame(&self, flow: u16, payload: &[u8]) {
        if payload.is_empty() {
            return;
        }
        let tx = self.map.lock().unwrap().get(&flow).cloned();
        if let Some(tx) = tx {
            // A full queue drops the frame, as a congested network would.
            let _ = tx.try_send(Bytes::copy_from_slice(payload));
        }
    }
}

/// Sends frames over an iroh connection: as datagrams when they fit, else on a uni stream.
pub struct IrohSender {
    conn: Connection,
    stats: Arc<TunnelStats>,
    streams: Arc<AtomicUsize>,
}

impl IrohSender {
    pub fn new(conn: Connection, stats: Arc<TunnelStats>) -> IrohSender {
        IrohSender { conn, stats, streams: Arc::new(AtomicUsize::new(0)) }
    }
}

impl FrameSink for IrohSender {
    /// A header-only datagram. Not counted as media; a lost one is covered by idle expiry.
    fn close_flow(&self, flow: u16) {
        let _ = self.conn.send_datagram(encode_frame(flow, &[]));
    }

    fn send_frame(&self, flow: u16, payload: &[u8]) {
        let frame = encode_frame(flow, payload);
        self.stats.wire_tx_pkts.fetch_add(1, Relaxed);
        self.stats.wire_tx_bytes.fetch_add(payload.len() as u64, Relaxed);
        let fits = self.conn.max_datagram_size().is_some_and(|max| frame.len() <= max);
        if fits {
            if self.conn.send_datagram(frame).is_err() {
                self.stats.dropped.fetch_add(1, Relaxed);
            }
            return;
        }
        if self.streams.fetch_add(1, Relaxed) >= MAX_STREAM_SENDS {
            self.streams.fetch_sub(1, Relaxed);
            self.stats.dropped.fetch_add(1, Relaxed);
            return;
        }
        self.stats.via_stream.fetch_add(1, Relaxed);
        let (conn, streams, stats) = (self.conn.clone(), self.streams.clone(), self.stats.clone());
        tokio::spawn(async move {
            let sent = async {
                let mut s = conn.open_uni().await.ok()?;
                s.write_all(&frame).await.ok()?;
                s.finish().ok()
            }
            .await;
            if sent.is_none() {
                stats.dropped.fetch_add(1, Relaxed);
            }
            streams.fetch_sub(1, Relaxed);
        });
    }
}

/// Reads frames from `conn` (datagrams and uni streams) into `on_frame` until it closes. A
/// frame with an empty payload means the sender closed that flow.
pub async fn pump<F>(conn: Connection, stats: Arc<TunnelStats>, on_frame: F)
where
    F: Fn(u16, Bytes) + Send + Sync + 'static,
{
    let on_frame = Arc::new(on_frame);
    let deliver = |frame: Bytes, on_frame: &F| {
        if let Some((flow, payload)) = decode_frame(&frame) {
            // An empty payload is a close for the flow; it is not media, so not counted.
            if !payload.is_empty() {
                stats.wire_rx_pkts.fetch_add(1, Relaxed);
                stats.wire_rx_bytes.fetch_add(payload.len() as u64, Relaxed);
            }
            on_frame(flow, frame.slice(FLOW_HEADER..));
        }
    };
    loop {
        tokio::select! {
            d = conn.read_datagram() => match d {
                Ok(d) => deliver(d, &on_frame),
                Err(_) => return,
            },
            u = conn.accept_uni() => match u {
                Ok(mut recv) => {
                    let (on_frame, stats) = (on_frame.clone(), stats.clone());
                    tokio::spawn(async move {
                        if let Ok(buf) = recv.read_to_end(MAX_STREAM_FRAME).await {
                            if let Some((flow, payload)) = decode_frame(&buf) {
                                if !payload.is_empty() {
                                    stats.wire_rx_pkts.fetch_add(1, Relaxed);
                                    stats.wire_rx_bytes.fetch_add(payload.len() as u64, Relaxed);
                                    on_frame(flow, Bytes::copy_from_slice(payload));
                                }
                            }
                        }
                    });
                }
                Err(_) => return,
            },
        }
    }
}

/// Serves one member's media connection on the host: its frames go to `target` (the host's
/// LiveKit UDP port) and the answers come back, until the connection closes.
/// `budget` is the member's flow budget, shared by all of its media connections here.
pub async fn serve_media_host(conn: Connection, target: SocketAddr, limits: FlowLimits, budget: Arc<FlowBudget>, stats: Arc<TunnelStats>) {
    let reply = Arc::new(IrohSender::new(conn.clone(), stats.clone()));
    let table = FlowTable::with_budget(target, reply, limits, budget, stats.clone());
    pump(conn, stats, move |flow, payload| table.send_frame(flow, &payload)).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::test_support::{stranger_net, two_member_nets};
    use tokio::time::timeout;

    const T: Duration = Duration::from_secs(3);

    /// A UDP echo server on loopback, standing in for LiveKit.
    async fn echo() -> SocketAddr {
        let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = s.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 70_000];
            while let Ok((n, from)) = s.recv_from(&mut buf).await {
                let _ = s.send_to(&buf[..n], from).await;
            }
        });
        addr
    }

    /// A sink that queues what it is given, and the queue's other end.
    struct Collect(mpsc::UnboundedSender<(u16, Vec<u8>)>);
    impl FrameSink for Collect {
        fn send_frame(&self, flow: u16, payload: &[u8]) {
            let _ = self.0.send((flow, payload.to_vec()));
        }
    }
    fn collector() -> (Arc<Collect>, mpsc::UnboundedReceiver<(u16, Vec<u8>)>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Collect(tx)), rx)
    }

    #[test]
    fn frames_carry_the_flow_id_big_endian() {
        let f = encode_frame(0x0102, b"abc");
        assert_eq!(&f[..], &[1, 2, b'a', b'b', b'c']);
        assert_eq!(decode_frame(&f), Some((0x0102, &b"abc"[..])));
        assert_eq!(decode_frame(&[7]), None, "too short for a flow id");
        assert_eq!(decode_frame(&[0, 9]), Some((9, &b""[..])));
    }

    #[tokio::test]
    async fn flow_table_forwards_and_replies_on_the_same_flow() {
        let (sink, mut rx) = collector();
        let stats = Arc::new(TunnelStats::default());
        let table = FlowTable::new(echo().await, sink, FlowLimits::default(), stats.clone());
        table.send_frame(5, b"one");
        table.send_frame(9, b"two");
        let mut got = vec![timeout(T, rx.recv()).await.unwrap().unwrap(), timeout(T, rx.recv()).await.unwrap().unwrap()];
        got.sort();
        assert_eq!(got, vec![(5, b"one".to_vec()), (9, b"two".to_vec())]);
        assert_eq!(table.flows(), 2, "one UDP socket per flow");
        assert_eq!(stats.up(), (2, 6));
        assert_eq!(stats.down(), (2, 6));
    }

    #[tokio::test]
    async fn flow_table_refuses_flows_beyond_the_cap() {
        let (sink, mut rx) = collector();
        let stats = Arc::new(TunnelStats::default());
        let limits = FlowLimits { max_flows: 2, idle: Duration::from_secs(30) };
        let table = FlowTable::new(echo().await, sink, limits, stats.clone());
        for flow in 1..=3 {
            table.send_frame(flow, b"x");
        }
        let mut answered = vec![];
        for _ in 0..2 {
            answered.push(timeout(T, rx.recv()).await.unwrap().unwrap().0);
        }
        answered.sort();
        assert_eq!(answered, vec![1, 2]);
        assert!(timeout(Duration::from_millis(300), rx.recv()).await.is_err(), "flow 3 must stay silent");
        assert_eq!(table.flows(), 2);
        assert_eq!(stats.flows_refused.load(Relaxed), 1);
        // An existing flow keeps working at the cap.
        table.send_frame(1, b"again");
        assert_eq!(timeout(T, rx.recv()).await.unwrap().unwrap(), (1, b"again".to_vec()));
    }

    #[tokio::test]
    async fn a_closed_flow_frees_its_place_at_once() {
        let (sink, mut rx) = collector();
        let stats = Arc::new(TunnelStats::default());
        let limits = FlowLimits { max_flows: 2, idle: Duration::from_secs(30) };
        let table = FlowTable::new(echo().await, sink, limits, stats.clone());
        table.send_frame(1, b"x");
        table.send_frame(2, b"x");
        for _ in 0..2 {
            timeout(T, rx.recv()).await.unwrap().unwrap();
        }
        table.close_flow(1);
        assert_eq!(table.flows(), 1);
        table.send_frame(3, b"x");
        assert_eq!(timeout(T, rx.recv()).await.unwrap().unwrap(), (3, b"x".to_vec()));
        assert_eq!(stats.flows_refused.load(Relaxed), 0);
        // A header-only frame is the wire form of a close.
        table.send_frame(2, b"");
        assert_eq!(table.flows(), 1);
    }

    #[tokio::test]
    async fn tables_sharing_a_budget_share_its_cap() {
        let (sink, mut rx) = collector();
        let stats = Arc::new(TunnelStats::default());
        let limits = FlowLimits { max_flows: 2, idle: Duration::from_secs(30) };
        let (target, budget) = (echo().await, FlowBudget::new(2));
        let a = FlowTable::with_budget(target, sink.clone(), limits, budget.clone(), stats.clone());
        let b = FlowTable::with_budget(target, sink, limits, budget.clone(), stats.clone());
        a.send_frame(1, b"x");
        b.send_frame(1, b"x");
        b.send_frame(2, b"x");
        for _ in 0..2 {
            timeout(T, rx.recv()).await.unwrap().unwrap();
        }
        assert!(timeout(Duration::from_millis(300), rx.recv()).await.is_err(), "the third flow, on either table, is refused");
        assert_eq!((a.flows() + b.flows(), budget.used(), stats.flows_refused.load(Relaxed)), (2, 2, 1));
        drop(a);
        assert_eq!(budget.used(), 1, "a dropped table gives its flows back");
    }

    #[test]
    fn a_member_may_hold_only_a_few_media_connections() {
        let reg = Arc::new(MemberMedia::default());
        let (me, other) = (MemberId([1; 32]), MemberId([2; 32]));
        let limits = FlowLimits::default();
        let permits: Vec<_> = (0..MAX_MEDIA_CONNS).map(|_| reg.admit(me, &limits).expect("within the cap")).collect();
        assert!(reg.admit(me, &limits).is_none(), "one connection too many");
        assert!(Arc::ptr_eq(&permits[0].budget, &permits[1].budget), "one budget per member");
        let theirs = reg.admit(other, &limits).expect("another member is unaffected");
        assert!(!Arc::ptr_eq(&permits[0].budget, &theirs.budget));
        drop(permits);
        assert!(reg.admit(me, &limits).is_some(), "closed connections free their slots");
        drop(theirs);
        assert_eq!(reg.members(), 0, "nothing is kept for members with no connection");
    }

    #[tokio::test]
    async fn several_connections_of_one_member_share_one_flow_cap() {
        let (a, b) = two_member_nets().await;
        let target = echo().await;
        let limits = FlowLimits { max_flows: 2, idle: Duration::from_secs(30) };
        let budget = FlowBudget::new(2);
        let host_stats = Arc::new(TunnelStats::default());
        let mut senders = vec![];
        let mut rxs = vec![];
        for _ in 0..3 {
            let conn_a = a.connect_addr(b.addr().await.unwrap(), a.media_alpn()).await.unwrap();
            let (_, _, conn_b) = b.accept().await.unwrap();
            tokio::spawn(serve_media_host(conn_b, target, limits, budget.clone(), host_stats.clone()));
            let (sink, rx) = collector();
            tokio::spawn(pump(conn_a.clone(), Arc::new(TunnelStats::default()), move |flow, p| sink.send_frame(flow, &p)));
            senders.push(IrohSender::new(conn_a, Arc::new(TunnelStats::default())));
            rxs.push(rx);
        }
        for (i, s) in senders.iter().enumerate() {
            s.send_frame(i as u16 + 1, b"hi");
        }
        let mut answered = 0;
        for rx in &mut rxs {
            if timeout(Duration::from_millis(700), rx.recv()).await.is_ok() {
                answered += 1;
            }
        }
        assert_eq!(answered, 2, "three connections, one flow each, but the member's cap is 2");
        assert_eq!(host_stats.flows_refused.load(Relaxed), 1);
        assert_eq!(budget.used(), 2);
    }

    #[tokio::test]
    async fn a_close_frame_over_the_wire_frees_the_hosts_flow() {
        let (a, b) = two_member_nets().await;
        let target = echo().await;
        let conn_a = a.connect_addr(b.addr().await.unwrap(), a.media_alpn()).await.unwrap();
        let (_, _, conn_b) = b.accept().await.unwrap();
        let budget = FlowBudget::new(16);
        tokio::spawn(serve_media_host(conn_b, target, FlowLimits::default(), budget.clone(), Arc::new(TunnelStats::default())));
        let (sink, mut rx) = collector();
        tokio::spawn(pump(conn_a.clone(), Arc::new(TunnelStats::default()), move |flow, p| sink.send_frame(flow, &p)));
        let sender = IrohSender::new(conn_a, Arc::new(TunnelStats::default()));
        sender.send_frame(7, b"open");
        timeout(T, rx.recv()).await.unwrap().unwrap();
        assert_eq!(budget.used(), 1);
        sender.close_flow(7);
        let t0 = Instant::now();
        while budget.used() != 0 {
            assert!(t0.elapsed() < T, "the host never dropped the closed flow");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn flow_table_expires_idle_flows_and_keeps_busy_ones() {
        let (sink, mut rx) = collector();
        let stats = Arc::new(TunnelStats::default());
        let limits = FlowLimits { max_flows: 8, idle: Duration::from_millis(400) };
        let table = FlowTable::new(echo().await, sink, limits, stats.clone());
        table.send_frame(1, b"idle");
        table.send_frame(2, b"busy");
        for _ in 0..2 {
            timeout(T, rx.recv()).await.unwrap().unwrap();
        }
        for _ in 0..6 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            table.send_frame(2, b"busy");
        }
        assert_eq!(table.flows(), 1, "the idle flow is gone, the busy one stays");
        assert_eq!(stats.flows_expired.load(Relaxed), 1);
    }

    #[tokio::test]
    async fn a_member_reaches_the_target_through_the_host_and_back() {
        let (a, b) = two_member_nets().await;
        let target = echo().await;
        let conn_a = a.connect_addr(b.addr().await.unwrap(), a.media_alpn()).await.unwrap();
        let (who, alpn, conn_b) = b.accept().await.unwrap();
        assert_eq!((who, alpn.as_slice()), (a.member_id(), b.media_alpn()));
        let host_stats = Arc::new(TunnelStats::default());
        tokio::spawn(serve_media_host(conn_b, target, FlowLimits::default(), FlowBudget::new(16), host_stats.clone()));
        let (sink, mut rx) = collector();
        tokio::spawn(pump(conn_a.clone(), Arc::new(TunnelStats::default()), move |flow, p| sink.send_frame(flow, &p)));
        let sender = IrohSender::new(conn_a, Arc::new(TunnelStats::default()));
        sender.send_frame(3, b"hello livekit");
        assert_eq!(timeout(T, rx.recv()).await.unwrap().unwrap(), (3, b"hello livekit".to_vec()));
        assert_eq!(host_stats.up(), (1, 13));
        assert_eq!(host_stats.down(), (1, 13));
    }

    #[tokio::test]
    async fn an_oversize_frame_still_arrives_on_a_uni_stream() {
        let (a, b) = two_member_nets().await;
        let target = echo().await;
        let conn_a = a.connect_addr(b.addr().await.unwrap(), a.media_alpn()).await.unwrap();
        let (_, _, conn_b) = b.accept().await.unwrap();
        let host_stats = Arc::new(TunnelStats::default());
        tokio::spawn(serve_media_host(conn_b, target, FlowLimits::default(), FlowBudget::new(16), host_stats.clone()));
        let (sink, mut rx) = collector();
        tokio::spawn(pump(conn_a.clone(), Arc::new(TunnelStats::default()), move |flow, p| sink.send_frame(flow, &p)));
        let stats = Arc::new(TunnelStats::default());
        let sender = IrohSender::new(conn_a, stats.clone());
        // Far above any datagram limit (about 1.2 KB at first, 1.4 KB after MTU discovery).
        let big: Vec<u8> = (0..9000u32).map(|i| (i % 251) as u8).collect();
        sender.send_frame(4, &big);
        let (flow, back) = timeout(T, rx.recv()).await.expect("oversize frame must come back").unwrap();
        assert_eq!((flow, back), (4, big));
        assert!(stats.via_stream.load(Relaxed) >= 1);
        assert_eq!(stats.dropped.load(Relaxed), 0);
    }

    #[tokio::test]
    async fn a_non_member_cannot_open_the_media_connection() {
        let (_a, b) = two_member_nets().await;
        let stranger = stranger_net().await;
        if let Ok(conn) = stranger.connect_addr(b.addr().await.unwrap(), b.media_alpn()).await {
            let err = timeout(Duration::from_secs(2), conn.closed()).await.expect("closed within 2 s");
            assert!(err.to_string().contains("403"), "unexpected close: {err}");
        }
        assert!(timeout(Duration::from_millis(500), b.accept()).await.is_err(), "the host never sees a stranger's flow");
    }
}
