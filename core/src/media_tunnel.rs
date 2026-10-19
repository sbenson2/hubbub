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

/// Bytes of flow id in front of each payload.
pub const FLOW_HEADER: usize = 2;
/// Largest frame accepted on a uni stream (a UDP datagram is at most 64 KiB).
const MAX_STREAM_FRAME: usize = 65_600;
/// Oversize frames in flight at once; more are dropped, as a full datagram queue would.
const MAX_STREAM_SENDS: usize = 8;
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

struct Flow {
    /// Used to send; a std socket, because a tokio one refuses its first sends until the
    /// reactor has registered it.
    send: std::net::UdpSocket,
    /// Milliseconds since the table started, of the last frame in either direction.
    last_ms: Arc<AtomicU64>,
    reader: JoinHandle<()>,
}

impl Drop for Flow {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

struct Table {
    target: SocketAddr,
    reply: Arc<dyn FrameSink>,
    limits: FlowLimits,
    epoch: Instant,
    flows: Mutex<HashMap<u16, Flow>>,
    stats: Arc<TunnelStats>,
}

/// The host-side forwarder for one member: frames in become UDP to `target` on a socket of
/// their own per flow; UDP coming back goes out through `reply` as frames on the same flow.
/// Flows open on their first frame, expire when idle and are capped.
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
        let table = Arc::new(Table {
            target,
            reply,
            limits,
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
        self.table.forward(flow, payload);
    }
}

impl Table {
    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    fn forward(self: &Arc<Self>, flow: u16, payload: &[u8]) {
        let mut flows = self.flows.lock().unwrap();
        if !flows.contains_key(&flow) {
            if flows.len() >= self.limits.max_flows {
                self.stats.flows_refused.fetch_add(1, Relaxed);
                return;
            }
            match self.open(flow) {
                Ok(f) => {
                    flows.insert(flow, f);
                    self.stats.flows_opened.fetch_add(1, Relaxed);
                }
                Err(e) => {
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
        Ok(Flow { send: std_sock, last_ms, reader })
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
    fn send_frame(&self, flow: u16, payload: &[u8]) {
        let frame = encode_frame(flow, payload);
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

/// Reads frames from `conn` (datagrams and uni streams) into `on_frame` until it closes.
pub async fn pump<F>(conn: Connection, on_frame: F)
where
    F: Fn(u16, Bytes) + Send + Sync + 'static,
{
    let on_frame = Arc::new(on_frame);
    let deliver = |frame: Bytes, on_frame: &F| {
        if let Some((flow, payload)) = decode_frame(&frame) {
            if !payload.is_empty() {
                on_frame(flow, frame.slice(FLOW_HEADER..));
            }
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
                    let on_frame = on_frame.clone();
                    tokio::spawn(async move {
                        if let Ok(buf) = recv.read_to_end(MAX_STREAM_FRAME).await {
                            if let Some((flow, payload)) = decode_frame(&buf) {
                                if !payload.is_empty() {
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
pub async fn serve_media_host(conn: Connection, target: SocketAddr, limits: FlowLimits, stats: Arc<TunnelStats>) {
    let reply = Arc::new(IrohSender::new(conn.clone(), stats.clone()));
    let table = FlowTable::new(target, reply, limits, stats);
    pump(conn, move |flow, payload| table.send_frame(flow, &payload)).await;
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
        tokio::spawn(serve_media_host(conn_b, target, FlowLimits::default(), host_stats.clone()));
        let (sink, mut rx) = collector();
        tokio::spawn(pump(conn_a.clone(), move |flow, p| sink.send_frame(flow, &p)));
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
        tokio::spawn(serve_media_host(conn_b, target, FlowLimits::default(), host_stats.clone()));
        let (sink, mut rx) = collector();
        tokio::spawn(pump(conn_a.clone(), move |flow, p| sink.send_frame(flow, &p)));
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
