//! Call media through the iroh tunnel, against the real vendored livekit-server.
//! LiveKit ports here avoid 7880-7882, which a running Hubbub may hold.
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::{LiveKitHost, LkPorts, MediaHost};
use hubbub_core::media_shim::IceConfig;
use hubbub_core::net::RelayChoice;
use hubbub_core::node::{Node, NodeConfig};
use iroh::EndpointAddr;
use tokio::time::timeout;
use webrtc_util::Conn;

const SIGNAL: u16 = 17980;
const RTC_UDP: u16 = 17982;

/// The vendored livekit-server for this OS, if there is one.
fn livekit_bin() -> Option<PathBuf> {
    let vendor = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vendor/livekit");
    let bin = if cfg!(windows) {
        vendor.join("windows-amd64/livekit-server.exe")
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        vendor.join("linux-amd64/livekit-server")
    } else {
        return None;
    };
    bin.exists().then_some(bin)
}

/// The source address the OS picks for the default route (sends nothing).
fn lan_ip() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    s.connect((Ipv4Addr::new(192, 0, 2, 1), 9)).ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

#[tokio::test]
async fn livekit_listens_on_loopback_and_nothing_on_a_real_interface() {
    let Some(bin) = livekit_bin() else { return };
    let Some(lan) = lan_ip() else { return };
    let work = tempfile::tempdir().unwrap();
    let ports = LkPorts { signal: SIGNAL, rtc_tcp: 0, rtc_udp: RTC_UDP };
    let mut host = LiveKitHost::new(bin, work.path().to_path_buf(), ports);
    let signal = host.start(IpAddr::V4(Ipv4Addr::LOCALHOST)).await.expect("livekit starts");
    assert_eq!(signal, SocketAddr::from(([127, 0, 0, 1], SIGNAL)));
    assert_eq!(host.rtc_port(), RTC_UDP);

    // Loopback is taken (by LiveKit), so the media port really is open there ...
    assert!(UdpSocket::bind((Ipv4Addr::LOCALHOST, RTC_UDP)).is_err(), "LiveKit must hold 127.0.0.1:{RTC_UDP}/udp");
    // ... while the same ports on the LAN address are free: a socket of LiveKit's on any real
    // interface (or the wildcard) would make these binds fail, and would raise the firewall prompt.
    UdpSocket::bind((lan, RTC_UDP)).unwrap_or_else(|e| panic!("LiveKit holds UDP {RTC_UDP} on {lan}: {e}"));
    TcpListener::bind((lan, SIGNAL)).unwrap_or_else(|e| panic!("LiveKit holds TCP {SIGNAL} on {lan}: {e}"));
    // No ICE-TCP listener (livekit's default would bind 7881 on every interface).
    host.stop().await;
}

// ---- the tunnel between real nodes, with a UDP echo in place of LiveKit ----

/// A media host whose "LiveKit" UDP port answers every packet with `<tag><packet>`, and counts them.
struct EchoHost {
    tag: u8,
    sock: Option<Arc<tokio::net::UdpSocket>>,
    port: u16,
    seen: Arc<AtomicU64>,
}

impl EchoHost {
    fn new(tag: u8) -> (EchoHost, Arc<AtomicU64>) {
        let std = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        std.set_nonblocking(true).unwrap();
        let port = std.local_addr().unwrap().port();
        let seen = Arc::new(AtomicU64::new(0));
        let sock = Some(Arc::new(tokio::net::UdpSocket::from_std(std).expect("inside a runtime")));
        (EchoHost { tag, sock, port, seen: seen.clone() }, seen)
    }
}

#[async_trait::async_trait]
impl MediaHost for EchoHost {
    async fn start(&mut self, _node_ip: IpAddr) -> anyhow::Result<SocketAddr> {
        let (sock, tag, seen) = (self.sock.clone().unwrap(), self.tag, self.seen.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 2048];
            while let Ok((n, from)) = sock.recv_from(&mut buf).await {
                seen.fetch_add(1, Ordering::SeqCst);
                let mut reply = vec![tag];
                reply.extend_from_slice(&buf[..n]);
                let _ = sock.send_to(&reply, from).await;
            }
        });
        Ok(SocketAddr::from(([127, 0, 0, 1], 9)))
    }
    async fn stop(&mut self) {}
    fn mint(&self, member: &MemberId, _name: &str, room: &str) -> anyhow::Result<String> {
        Ok(format!("echo:{member}:{room}"))
    }
    fn rtc_port(&self) -> u16 {
        self.port
    }
}

fn community(can_host: &[bool]) -> (Vec<tempfile::TempDir>, PathBuf) {
    let dirs: Vec<tempfile::TempDir> = can_host.iter().map(|_| tempfile::tempdir().unwrap()).collect();
    let ids: Vec<Identity> = dirs.iter().map(|d| Identity::load_or_create(d.path()).unwrap()).collect();
    let names: Vec<String> = (0..ids.len()).map(|i| format!("node{i}")).collect();
    let members: Vec<(&Identity, &str, bool)> =
        ids.iter().zip(&names).zip(can_host).map(|((id, n), &h)| (id, n.as_str(), h)).collect();
    let state = CommunityState::for_tests("media", &members);
    let file = dirs[0].path().join("community.json");
    state.save_atomic(&file).unwrap();
    (dirs, file)
}

fn config(dir: &tempfile::TempDir, file: &Path, can_host: bool) -> NodeConfig {
    NodeConfig {
        data_dir: dir.path().to_path_buf(),
        community_file: file.to_path_buf(),
        can_host,
        relay: RelayChoice::Disabled,
    }
}

/// Nodes with echo hosts (tag = index, tag byte `b'0' + index`), each dialing the earlier ones.
async fn echo_cluster(can_host: &[bool]) -> (Vec<Node>, Vec<Arc<AtomicU64>>) {
    let (dirs, file) = community(can_host);
    let (mut nodes, mut seen, mut addrs): (Vec<Node>, Vec<Arc<AtomicU64>>, Vec<EndpointAddr>) = Default::default();
    for (i, (dir, &host)) in dirs.iter().zip(can_host).enumerate() {
        let (echo, counter) = EchoHost::new(b'0' + i as u8);
        let node = Node::start_with_addrs(config(dir, &file, host), Box::new(echo), addrs.clone()).await.unwrap();
        addrs.push(node.endpoint_addr().await.unwrap());
        seen.push(counter);
        nodes.push(node);
    }
    (nodes, seen)
}

async fn wait_agree(ns: &[Node], within: Duration) -> MemberId {
    let start = Instant::now();
    loop {
        if let Some(host) = ns.first().and_then(|n| n.host_state().host) {
            if ns.iter().all(|n| n.host_state().host == Some(host)) && ns.iter().any(|n| n.member_id() == host) {
                return host;
            }
        }
        assert!(start.elapsed() < within, "no agreed host within {within:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// A TURN client of the node's shim, as LiveKit's client would be (libwebrtc cannot be driven
/// from here; `tools/relay-check` does that against a real LiveKit).
async fn turn_client(ice: &IceConfig, password: &str) -> turn::client::Client {
    let server = ice.url.strip_prefix("turn:").unwrap().split('?').next().unwrap().to_string();
    let sock = Arc::new(tokio::net::UdpSocket::bind("0.0.0.0:0").await.unwrap());
    let c = turn::client::Client::new(turn::client::ClientConfig {
        stun_serv_addr: server.clone(),
        turn_serv_addr: server,
        username: ice.username.clone(),
        password: password.to_string(),
        realm: String::new(),
        software: String::new(),
        rto_in_ms: 0,
        conn: sock,
        vnet: None,
    })
    .await
    .unwrap();
    c.listen().await.unwrap();
    c
}

const PEER: &str = "203.0.113.9:7882";

/// Sends `msg` through a fresh allocation on `ice` and returns the reply, or `None` if silent.
async fn through(ice: &IceConfig, msg: &[u8], wait: Duration) -> Option<Vec<u8>> {
    let c = turn_client(ice, &ice.credential).await;
    let relay = timeout(Duration::from_secs(5), c.allocate()).await.ok()?.ok()?;
    relay.send_to(msg, PEER.parse().unwrap()).await.ok()?;
    let mut buf = [0u8; 256];
    let (n, _) = timeout(wait, relay.recv_from(&mut buf)).await.ok()?.ok()?;
    Some(buf[..n].to_vec())
}

#[tokio::test]
async fn a_members_media_reaches_the_hosts_port_and_back_through_the_tunnel() {
    let (ns, seen) = echo_cluster(&[true, false]).await;
    let host = wait_agree(&ns, Duration::from_secs(5)).await;
    assert_eq!(host, ns[0].member_id());
    let creds = ns[1].voice_credentials("lobby").await.unwrap();
    let Some(ice) = creds.ice else { return eprintln!("no usable network address on this machine; skipped") };
    assert!(ice.url.starts_with("turn:") && ice.url.ends_with("?transport=udp"), "{}", ice.url);
    assert!(!ice.url.contains("127.0.0.1"), "libwebrtc ignores loopback: {}", ice.url);

    let t0 = Instant::now();
    let reply = through(&ice, b"hello host", Duration::from_secs(2)).await.expect("the host's port answered");
    assert_eq!(reply, b"0hello host", "answered by the host's port (tag 0)");
    let took = t0.elapsed();
    assert!(took < Duration::from_secs(2), "first packet round trip took {took:?}");
    assert_eq!(seen[0].load(Ordering::SeqCst), 1);
    assert_eq!(seen[1].load(Ordering::SeqCst), 0, "the member's own port is never involved");
    println!("tunnel first-packet round trip: {took:?}");

    // Many packets, in order, none lost on a quiet path.
    let c = turn_client(&ice, &ice.credential).await;
    let relay = c.allocate().await.unwrap();
    let mut got = 0;
    for i in 0..200u32 {
        relay.send_to(&i.to_be_bytes(), PEER.parse().unwrap()).await.unwrap();
        let mut buf = [0u8; 64];
        if let Ok(Ok((n, _))) = timeout(Duration::from_secs(1), relay.recv_from(&mut buf)).await {
            assert_eq!(&buf[..n], [&[b'0'][..], &i.to_be_bytes()[..]].concat());
            got += 1;
        }
    }
    assert_eq!(got, 200, "all 200 request/reply pairs crossed the tunnel");
    // The counters are the evidence: 201 packets up the wire from the member, all forwarded to
    // the host's port, and as many back.
    let (m, h) = (ns[1].media_stats(), ns[0].media_stats());
    assert_eq!((m.wire_tx_pkts, m.wire_rx_pkts), (201, 201));
    assert_eq!((h.wire_rx_pkts, h.to_livekit_pkts, h.from_livekit_pkts, h.wire_tx_pkts), (201, 201, 201, 201));
    assert_eq!((m.dropped, h.dropped, m.via_stream), (0, 0, 0));
}

/// A screen share's worth of media: at least 6 Mbps in 1200-byte packets, one way (the pacing
/// below is bursty, so the measured rate is printed and checked).
#[tokio::test]
async fn a_screen_share_rate_crosses_the_tunnel() {
    let (ns, seen) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let Some(ice) = ns[1].voice_credentials("lobby").await.unwrap().ice else { return };
    let c = turn_client(&ice, &ice.credential).await;
    let relay = Arc::new(c.allocate().await.unwrap());
    let received = Arc::new(AtomicU64::new(0));
    let rx = {
        let (relay, received) = (relay.clone(), received.clone());
        tokio::spawn(async move {
            let mut buf = [0u8; 2048];
            while let Ok((_, _)) = relay.recv_from(&mut buf).await {
                received.fetch_add(1, Ordering::SeqCst);
            }
        })
    };
    // Nominally 5 packets every 4 ms = 12 Mbps; the interval catches up after a late tick.
    let (packets, payload) = (1875u64, vec![7u8; 1200]);
    let t0 = Instant::now();
    let mut tick = tokio::time::interval(Duration::from_millis(4));
    for _ in 0..packets / 5 {
        tick.tick().await;
        for _ in 0..5 {
            relay.send_to(&payload, PEER.parse().unwrap()).await.unwrap();
        }
    }
    let sent_for = t0.elapsed();
    tokio::time::sleep(Duration::from_millis(500)).await;
    rx.abort();
    let at_host = seen[0].load(Ordering::SeqCst);
    let back = received.load(Ordering::SeqCst);
    let mbps = packets as f64 * 1200.0 * 8.0 / sent_for.as_secs_f64() / 1e6;
    println!("tunnel: sent {packets} x 1200 B in {sent_for:?} ({mbps:.1} Mbps), host port saw {at_host}, {back} came back; member counters {:?}", ns[1].media_stats());
    assert!(mbps >= 6.0, "the test must offer at least 6 Mbps, offered {mbps:.1}");
    // A cold connection is still in QUIC slow start, which drops datagrams rather than queueing
    // them (right for real-time media); a 10 s run in the spike lost 0.05% at 6 and 20 Mbps.
    assert!(at_host >= packets * 95 / 100, "host port saw only {at_host} of {packets}");
    assert!(back >= packets * 95 / 100, "only {back} of {packets} came back");
}

#[tokio::test]
async fn the_hosts_own_client_uses_the_shim_straight_to_its_port() {
    let (ns, seen) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let creds = ns[0].voice_credentials("lobby").await.unwrap();
    let Some(ice) = creds.ice else { return eprintln!("no usable network address; skipped") };
    assert_eq!(through(&ice, b"self", Duration::from_secs(2)).await.unwrap(), b"0self");
    assert_eq!(seen[0].load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_shim_needs_its_own_credential() {
    let (ns, seen) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let Some(ice) = ns[1].voice_credentials("lobby").await.unwrap().ice else { return };
    let c = turn_client(&ice, "guess").await;
    assert!(timeout(Duration::from_secs(5), c.allocate()).await.expect("answered").is_err());
    assert_eq!(seen[0].load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn after_a_host_change_the_shim_points_at_the_new_host() {
    let (mut ns, _) = echo_cluster(&[true, true, false]).await;
    let host = wait_agree(&ns, Duration::from_secs(5)).await;
    // Node 2 cannot host; it is the member whose call follows the host.
    let member_id = ns[2].member_id();
    let first = ns[2].voice_credentials("lobby").await.unwrap();
    let Some(ice1) = first.ice.clone() else { return eprintln!("no usable network address; skipped") };
    let host_index = ns.iter().position(|n| n.member_id() == host).unwrap();
    let tag_of = |i: usize| [b'0' + i as u8];
    assert_eq!(through(&ice1, b"one", Duration::from_secs(2)).await.unwrap(), [&tag_of(host_index)[..], b"one"].concat());

    // A call in flight on the old host's allocation.
    let old_client = turn_client(&ice1, &ice1.credential).await;
    let old_relay = old_client.allocate().await.unwrap();

    let t0 = Instant::now();
    drop(ns.remove(host_index)); // hard kill: no Resign
    let new_host = wait_agree(&ns, Duration::from_millis(4_000)).await;
    assert_ne!(new_host, host);
    let member_node = ns.iter().find(|n| n.member_id() == member_id).unwrap();
    let second = member_node.voice_credentials("lobby").await.unwrap();
    assert_eq!(second.host, new_host);
    let ice2 = second.ice.unwrap();
    assert_eq!(ice2, ice1, "same shim: the app needs no new ICE server, only to rejoin");

    // The old allocation is dead, and nothing it sends reaches anyone.
    let _ = old_relay.send_to(b"stale", PEER.parse().unwrap()).await;
    let mut buf = [0u8; 64];
    assert!(timeout(Duration::from_millis(800), old_relay.recv_from(&mut buf)).await.is_err());
    // The rejoin allocates afresh and reaches the new host's port.
    let new_index = 1 - host_index; // the other host-capable node
    let reply = through(&ice2, b"two", Duration::from_secs(3)).await.expect("new host answers");
    assert_eq!(reply, [&tag_of(new_index)[..], b"two"].concat());
    println!("host change to media through the new host: {:?}", t0.elapsed());
}

#[tokio::test]
async fn a_node_that_shut_down_no_longer_runs_a_shim() {
    let (ns, _) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let Some(ice) = ns[1].voice_credentials("lobby").await.unwrap().ice else { return eprintln!("no usable network address; skipped") };
    assert!(through(&ice, b"up", Duration::from_secs(2)).await.is_some());
    ns[1].shutdown_ref().await;
    assert!(through(&ice, b"down", Duration::from_secs(1)).await.is_none(), "the shim must be gone");
}

/// A LiveKit client opens its subscriber and publisher peer connections almost together, so two
/// allocations arrive at a cold member at once. They must share one connection to the host.
#[tokio::test]
async fn concurrent_first_allocations_both_get_media_both_ways() {
    let (ns, seen) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let Some(ice) = ns[1].voice_credentials("lobby").await.unwrap().ice else { return eprintln!("no usable network address; skipped") };
    let (c1, c2) = (turn_client(&ice, &ice.credential).await, turn_client(&ice, &ice.credential).await);
    let (r1, r2) = tokio::join!(c1.allocate(), c2.allocate());
    let (r1, r2) = (r1.expect("first allocation"), r2.expect("second allocation"));
    for round in 0..3u8 {
        for (i, relay) in [&r1, &r2].into_iter().enumerate() {
            let msg = [round, i as u8];
            relay.send_to(&msg, PEER.parse().unwrap()).await.unwrap();
            let mut buf = [0u8; 64];
            let (n, _) = timeout(Duration::from_secs(2), relay.recv_from(&mut buf))
                .await
                .unwrap_or_else(|_| panic!("allocation {i} got no reply in round {round}"))
                .unwrap();
            assert_eq!(&buf[..n], [&b"0"[..], &msg[..]].concat());
        }
    }
    assert_eq!(seen[0].load(Ordering::SeqCst), 6);
    assert_eq!(ns[0].media_stats().flows_opened, 2);
}

/// Ending an allocation tells the host, so reconnect churn does not pile up dead flows against
/// the cap (16) while their 30 s idle expiry runs.
#[tokio::test]
async fn closed_allocations_do_not_use_up_the_hosts_flow_cap() {
    let (ns, _) = echo_cluster(&[true, false]).await;
    wait_agree(&ns, Duration::from_secs(5)).await;
    let Some(ice) = ns[1].voice_credentials("lobby").await.unwrap().ice else { return eprintln!("no usable network address; skipped") };
    for i in 0..24u8 {
        let c = turn_client(&ice, &ice.credential).await;
        let relay = timeout(Duration::from_secs(5), c.allocate()).await.expect("allocation").expect("allocated");
        relay.send_to(&[i], PEER.parse().unwrap()).await.unwrap();
        let mut buf = [0u8; 16];
        let (n, _) = timeout(Duration::from_secs(2), relay.recv_from(&mut buf))
            .await
            .unwrap_or_else(|_| panic!("allocation {i} got no reply"))
            .unwrap();
        assert_eq!(&buf[..n], [b'0', i]);
        relay.close().await.unwrap();
        // Let the refresh-to-zero and the close frame land before the next one.
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    let fresh = through(&ice, b"fresh", Duration::from_secs(2)).await;
    assert_eq!(fresh.as_deref(), Some(&b"0fresh"[..]), "a fresh allocation still gets media");
    let h = ns[0].media_stats();
    assert_eq!(h.flows_refused, 0, "dead flows must not count against the cap");
    assert_eq!(h.flows_opened, 25);
}
