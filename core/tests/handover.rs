//! Host hand-over with in-process nodes: FakeHost media, relays disabled.
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::{FakeHost, MediaHost};
use hubbub_core::net::{Net, RelayChoice};
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use hubbub_core::proto::{read_msg, write_msg, CtlMsg};
use iroh::EndpointAddr;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::broadcast;

/// How long a silent peer keeps its session before the node closes it (node.rs).
const SILENCE_LIMIT: Duration = Duration::from_secs(3);

/// One identity per entry in its own temp dir, and a community file listing them all.
fn community(can_host: &[bool]) -> (Vec<tempfile::TempDir>, PathBuf) {
    let dirs: Vec<tempfile::TempDir> = can_host.iter().map(|_| tempfile::tempdir().unwrap()).collect();
    let ids: Vec<Identity> = dirs.iter().map(|d| Identity::load_or_create(d.path()).unwrap()).collect();
    let names: Vec<String> = (0..ids.len()).map(|i| format!("node{i}")).collect();
    let members: Vec<(&Identity, &str, bool)> =
        ids.iter().zip(&names).zip(can_host).map(|((id, n), &h)| (id, n.as_str(), h)).collect();
    let community = CommunityState::for_tests("handover", &members);
    let community_file = dirs[0].path().join("community.json");
    community.save_atomic(&community_file).unwrap();
    (dirs, community_file)
}

fn config(dir: &tempfile::TempDir, community_file: &Path, can_host: bool) -> NodeConfig {
    NodeConfig {
        data_dir: dir.path().to_path_buf(),
        community_file: community_file.to_path_buf(),
        can_host,
        relay: RelayChoice::Disabled,
    }
}

/// Nodes sharing one community, each with an event receiver subscribed as it starts, so no
/// event is missed. Node i starts with the addresses of nodes 0..i, so every pair has a dialer.
async fn cluster_watched(
    can_host: &[bool],
    media: Vec<Box<dyn MediaHost>>,
) -> (Vec<Node>, Vec<broadcast::Receiver<NodeEvent>>) {
    let (dirs, community_file) = community(can_host);
    let mut nodes: Vec<Node> = Vec::new();
    let mut events = Vec::new();
    let mut addrs = Vec::new();
    for ((dir, &host), media) in dirs.iter().zip(can_host).zip(media) {
        let node = Node::start_with_addrs(config(dir, &community_file, host), media, addrs.clone()).await.unwrap();
        events.push(node.subscribe());
        addrs.push(node.endpoint_addr().await.unwrap());
        nodes.push(node);
    }
    // Nodes read the identity and community files at start, so the temp dirs can go now.
    (nodes, events)
}

async fn cluster_with(can_host: &[bool], media: Vec<Box<dyn MediaHost>>) -> Vec<Node> {
    cluster_watched(can_host, media).await.0
}

/// Starts a node on a runtime thread of its own. Sending on the returned channel freezes it:
/// the thread stops driving that runtime, so the node's socket stays open but nothing answers
/// and no CONNECTION_CLOSE goes out, as after a kill -9, a power loss or a dropped network.
async fn start_freezable(cfg: NodeConfig, addrs: Vec<EndpointAddr>) -> (Node, EndpointAddr, std::sync::mpsc::Sender<()>) {
    let (ready_tx, ready) = tokio::sync::oneshot::channel();
    let (freeze, frozen) = std::sync::mpsc::channel::<()>();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let node = Node::start_with_addrs(cfg, Box::new(FakeHost::new()), addrs).await.unwrap();
            let addr = node.endpoint_addr().await.unwrap();
            let _ = ready_tx.send((node, addr));
            while matches!(frozen.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)) {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        });
        // Frozen: the runtime and its sockets stay alive, but nothing drives them again.
        loop {
            std::thread::park();
        }
    });
    let (node, addr) = ready.await.unwrap();
    (node, addr, freeze)
}

/// Like `cluster`, with every node on its own runtime thread so the test can freeze it.
async fn freezable_cluster(can_host: &[bool]) -> (Vec<Node>, Vec<std::sync::mpsc::Sender<()>>) {
    let (dirs, community_file) = community(can_host);
    let (mut nodes, mut freezers, mut addrs) = (Vec::new(), Vec::new(), Vec::new());
    for (dir, &host) in dirs.iter().zip(can_host) {
        let (node, addr, freeze) = start_freezable(config(dir, &community_file, host), addrs.clone()).await;
        addrs.push(addr);
        nodes.push(node);
        freezers.push(freeze);
    }
    (nodes, freezers)
}

async fn cluster(n: usize, can_host: &[bool], fail_start: &[bool]) -> Vec<Node> {
    assert_eq!((can_host.len(), fail_start.len()), (n, n));
    let media = fail_start
        .iter()
        .map(|&fail| -> Box<dyn MediaHost> {
            if fail {
                Box::new(FakeHost::failing())
            } else {
                Box::new(FakeHost::new())
            }
        })
        .collect();
    cluster_with(can_host, media).await
}

/// Polls `f` every 10 ms until it returns `Some`; panics after `within`.
async fn wait_for<T>(within: Duration, what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let start = Instant::now();
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(start.elapsed() < within, "timed out after {within:?} waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// The host every node in `ns` names, when they all name the same one and it is one of them.
fn agreed_host(ns: &[Node]) -> Option<MemberId> {
    let host = ns.first()?.host_state().host?;
    let all_agree = ns.iter().all(|n| n.host_state().host == Some(host));
    let host_is_live = ns.iter().any(|n| n.member_id() == host);
    (all_agree && host_is_live).then_some(host)
}

async fn wait_agree(ns: &[Node], within: Duration) -> MemberId {
    let states = || ns.iter().map(|n| (n.member_id().tag(), n.host_state())).collect::<Vec<_>>();
    let start = Instant::now();
    loop {
        if let Some(host) = agreed_host(ns) {
            return host;
        }
        assert!(start.elapsed() < within, "no agreed host within {within:?}: {:?}", states());
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Drops the node: no Resign and no graceful close (the hard-kill path).
fn drop_node_without_resign(ns: &mut Vec<Node>, member: MemberId) {
    let i = ns.iter().position(|n| n.member_id() == member).expect("node is in the cluster");
    drop(ns.remove(i));
}

/// Writes `msg` to the TCP port of a `ws://127.0.0.1:port` URL and reads as many bytes back.
async fn echo_via(url: &str, msg: &[u8]) -> Vec<u8> {
    let addr: SocketAddr = url.strip_prefix("ws://").expect("a ws:// url").parse().unwrap();
    let io = async {
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        s.write_all(msg).await.unwrap();
        let mut back = vec![0u8; msg.len()];
        s.read_exact(&mut back).await.unwrap();
        back
    };
    tokio::time::timeout(Duration::from_secs(5), io).await.expect("echo within 5 s")
}

/// Every event already queued on `rx`.
fn drain(rx: &mut broadcast::Receiver<NodeEvent>) -> Vec<NodeEvent> {
    std::iter::from_fn(|| rx.try_recv().ok()).collect()
}

/// Waits until `rx` yields `PeerDown { member }`; panics at `deadline`.
async fn wait_peer_down(rx: &mut broadcast::Receiver<NodeEvent>, member: MemberId, deadline: Instant, who: &str) {
    let down = async {
        loop {
            if let NodeEvent::PeerDown { member: m } = rx.recv().await.unwrap() {
                if m == member {
                    return;
                }
            }
        }
    };
    let left = deadline.saturating_duration_since(Instant::now());
    tokio::time::timeout(left, down).await.unwrap_or_else(|_| panic!("{who} never saw the silent peer go down"));
}

#[tokio::test]
async fn three_nodes_agree_on_one_host() {
    let ns = cluster(3, &[true; 3], &[false; 3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    assert_eq!(ns.iter().filter(|n| n.host_state().host == Some(n.member_id())).count(), 1);
    let _ = host;
}

#[tokio::test]
async fn hard_kill_handover_under_2_5s_and_creds_follow() {
    let mut ns = cluster(3, &[true; 3], &[false; 3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    let mut watcher = ns.iter().find(|n| n.member_id() != host).unwrap().subscribe();
    let t0 = Instant::now();
    drop_node_without_resign(&mut ns, host);
    let new_host = wait_agree(&ns, Duration::from_millis(2_500)).await;
    let took = t0.elapsed();
    assert_ne!(new_host, host);
    assert!(took < Duration::from_millis(2_500), "hand-over took {took:?}");
    let saw_close = std::iter::from_fn(|| watcher.try_recv().ok())
        .any(|e| matches!(e, NodeEvent::PeerDown { member } if member == host));
    let seen_as = if saw_close { "a connection close" } else { "silence" };
    println!("hard-kill hand-over took {took:?}; the killed host looked like {seen_as}");

    let follower = ns.iter().find(|n| n.member_id() != new_host).unwrap();
    let c = follower.voice_credentials("lobby").await.unwrap();
    assert_eq!(c.host, new_host);
    assert_eq!(c.token, format!("fake:{}:{}.lobby", follower.member_id(), follower.community_id()));
    assert_eq!(echo_via(&c.url, b"ping").await, b"ping"); // tunnel reaches the new host's FakeHost
}

#[tokio::test]
async fn graceful_shutdown_handover_under_1s() {
    let mut ns = cluster(3, &[true; 3], &[false; 3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    let i = ns.iter().position(|n| n.member_id() == host).unwrap();
    let old = ns.remove(i);
    let t0 = Instant::now();
    let shutdown = tokio::spawn(old.shutdown());
    let new_host = wait_agree(&ns, Duration::from_secs(1)).await;
    let took = t0.elapsed();
    assert_ne!(new_host, host);
    assert!(took < Duration::from_secs(1), "hand-over took {took:?}");
    println!("graceful hand-over took {took:?}");
    tokio::time::timeout(Duration::from_secs(5), shutdown).await.expect("shutdown within 5 s").unwrap();
}

#[tokio::test]
async fn phone_member_never_hosts() {
    let mut ns = cluster(2, &[true, false], &[false, false]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    assert_eq!(host, ns[0].member_id());
    let mut events = ns[1].subscribe();
    drop_node_without_resign(&mut ns, host);
    let no_host = async {
        loop {
            if matches!(events.recv().await.unwrap(), NodeEvent::HostChanged { host: None, .. }) {
                return;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(4), no_host).await.expect("phone reports no host");
    assert_eq!(ns[0].host_state().host, None);
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(ns[0].host_state().host, None, "a phone never claims the host role");
}

/// A FakeHost whose `start` fails for whichever node in the cluster calls it first. That node
/// is the would-be winner, which is decided by measured upload and so is not known in advance.
struct FirstStartFails {
    index: usize,
    failed: Arc<Mutex<Option<usize>>>,
    inner: FakeHost,
}

#[async_trait::async_trait]
impl MediaHost for FirstStartFails {
    async fn start(&mut self, node_ip: IpAddr) -> anyhow::Result<SocketAddr> {
        let first = {
            let mut failed = self.failed.lock().unwrap();
            let first = failed.is_none();
            if first {
                *failed = Some(self.index);
            }
            first
        };
        if first {
            anyhow::bail!("the first start in the cluster fails");
        }
        self.inner.start(node_ip).await
    }

    async fn stop(&mut self) {
        self.inner.stop().await
    }

    fn mint(&self, member: &MemberId, name: &str, room: &str) -> anyhow::Result<String> {
        self.inner.mint(member, name, room)
    }
}

#[tokio::test]
async fn host_start_failure_resigns() {
    let failed = Arc::new(Mutex::new(None));
    let media = (0..2)
        .map(|index| -> Box<dyn MediaHost> {
            Box::new(FirstStartFails { index, failed: failed.clone(), inner: FakeHost::new() })
        })
        .collect();
    let ns = cluster_with(&[true, true], media).await;
    let mut events: Vec<_> = ns.iter().map(|n| n.subscribe()).collect();

    let survivor = wait_for(Duration::from_secs(4), "the other node to host after a failed start", || {
        let f = (*failed.lock().unwrap())?;
        let other = ns[1 - f].member_id();
        (agreed_host(&ns)? == other).then_some(other)
    })
    .await;
    let f = failed.lock().unwrap().unwrap();
    let resigned = std::iter::from_fn(|| events[f].try_recv().ok())
        .any(|e| matches!(e, NodeEvent::HostChanged { host: None, .. }));
    assert!(resigned, "the node whose start failed emits HostChanged {{ host: None }}");

    let c = ns[f].voice_credentials("lobby").await.unwrap();
    assert_eq!(c.host, survivor);
    assert_eq!(c.token, format!("fake:{}:{}.lobby", ns[f].member_id(), ns[f].community_id()));
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(agreed_host(&ns), Some(survivor), "no dead host remains");
}

/// R23 + R33: a host that goes silent, with no CONNECTION_CLOSE, is replaced once the survivors
/// close its session after 3 s of silence (`PeerDown`), not on a shorter heartbeat gap.
#[tokio::test]
async fn silent_host_handover_and_its_sessions_close() {
    let (mut ns, freezers) = freezable_cluster(&[true; 3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    // Let the startup probes finish, so they do not slow the timers under test.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(agreed_host(&ns), Some(host), "the host is stable before it goes silent");
    let i = ns.iter().position(|n| n.member_id() == host).unwrap();
    let mut watchers: Vec<_> = ns.iter().filter(|n| n.member_id() != host).map(|n| n.subscribe()).collect();
    let t0 = Instant::now();
    freezers[i].send(()).unwrap();
    let _frozen = ns.remove(i);

    // The session's silence limit, then a claim and its Announce.
    let bound = SILENCE_LIMIT + Duration::from_millis(1_500);
    let new_host = wait_agree(&ns, bound).await;
    let took = t0.elapsed();
    assert_ne!(new_host, host);
    assert!(took >= Duration::from_secs(2), "R33: heartbeat silence alone replaced the host after {took:?}");
    assert!(took < bound, "silent-host hand-over took {took:?}");
    println!("silent-host hand-over took {took:?}");

    let follower = ns.iter().find(|n| n.member_id() != new_host).unwrap();
    let c = follower.voice_credentials("lobby").await.unwrap();
    assert_eq!(c.host, new_host);
    assert_eq!(echo_via(&c.url, b"ping").await, b"ping");

    let deadline = t0 + SILENCE_LIMIT + Duration::from_millis(1_500);
    for (k, w) in watchers.iter_mut().enumerate() {
        wait_peer_down(w, host, deadline, &format!("survivor {k}")).await;
    }
    println!("silent host's sessions closed after {:?}", t0.elapsed());
}

/// R23, the review's scenario: the host and another member go silent together. The survivor may
/// rank below the silent member, so it can claim only once that member's session closes.
#[tokio::test]
async fn silent_host_and_member_survivor_takes_over() {
    let (mut ns, freezers) = freezable_cluster(&[true; 3]).await;
    let host = wait_agree(&ns, Duration::from_secs(4)).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    // With equal measurements the lower id ranks higher, so keep the higher id of the two
    // others: the silent member then most likely outranks the survivor.
    let survivor = ns.iter().map(|n| n.member_id()).filter(|m| *m != host).max().unwrap();
    let t0 = Instant::now();
    for (n, freeze) in ns.iter().zip(&freezers) {
        if n.member_id() != survivor {
            freeze.send(()).unwrap();
        }
    }
    let s = ns.iter().position(|n| n.member_id() == survivor).unwrap();
    let alone = [ns.swap_remove(s)];

    let bound = SILENCE_LIMIT + Duration::from_millis(1_500);
    assert_eq!(wait_agree(&alone, bound).await, survivor);
    println!("survivor took over after {:?}", t0.elapsed());
}

/// R24: two members listed as unable to host never connect to each other; both follow the desktop.
#[tokio::test]
async fn phones_never_connect_to_each_other() {
    let media = (0..3).map(|_| -> Box<dyn MediaHost> { Box::new(FakeHost::new()) }).collect();
    let (ns, mut events) = cluster_watched(&[true, false, false], media).await;
    let desktop = ns[0].member_id();
    assert_eq!(wait_agree(&ns, Duration::from_secs(4)).await, desktop);
    for (i, j) in [(1, 2), (2, 1)] {
        let seen = drain(&mut events[i]);
        let up = |m: MemberId| seen.iter().any(|e| matches!(e, NodeEvent::PeerUp { member, .. } if *member == m));
        assert!(up(desktop), "phone {i} connects to the desktop: {seen:?}");
        assert!(!up(ns[j].member_id()), "phone {i} never connects to phone {j}: {seen:?}");
    }
}

/// R24: a phone closes a control connection from another phone, even one that dials anyway.
#[tokio::test]
async fn phone_closes_a_control_connection_from_another_phone() {
    let (dirs, community_file) = community(&[false, false]);
    let cfg = config(&dirs[0], &community_file, false);
    let node = Node::start_with_addrs(cfg, Box::new(FakeHost::new()), Vec::new()).await.unwrap();
    let mut events = node.subscribe();
    let addr = node.endpoint_addr().await.unwrap();

    let other = Identity::load_or_create(dirs[1].path()).unwrap();
    let community = Arc::new(CommunityState::load(&community_file).unwrap());
    let net = Net::bind(&other, tokio::sync::watch::channel(community).1, RelayChoice::Disabled).await.unwrap();
    let hello = CtlMsg::Hello { member: other.member_id(), can_host: false, online_since_ms: 0 };
    let answer = tokio::time::timeout(Duration::from_secs(5), async {
        let conn = net.connect_addr(addr, net.ctl_alpn()).await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_msg(&mut send, &hello).await?;
        read_msg(&mut recv).await
    })
    .await
    .expect("an answer or a close within 5 s");
    assert!(!matches!(answer, Ok(Some(CtlMsg::Hello { .. }))), "the phone answered Hello: {answer:?}");
    let seen = drain(&mut events);
    assert!(!seen.iter().any(|e| matches!(e, NodeEvent::PeerUp { .. })), "no session came up: {seen:?}");
}

/// R25: while the host probes a member whose path is too slow to take `PROBE_BYTES` in
/// `PROBE_MAX_TIME` (the member reads slowly, so flow control throttles the host's probe), the
/// member keeps hearing the host's heartbeats with no gap of 1 s, and the probe stops at its
/// time limit. The member also probes back, as a real member does.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe_never_starves_heartbeats_and_stops_at_its_time_limit() {
    use hubbub_core::probe::{send_probe, PROBE_BYTES, PROBE_MAX_TIME};
    let (dirs, community_file) = community(&[true, false]);
    let cfg = config(&dirs[0], &community_file, true);
    let node = Node::start_with_addrs(cfg, Box::new(FakeHost::new()), Vec::new()).await.unwrap();
    let host = node.member_id();
    wait_for(Duration::from_secs(4), "the node to host", || (node.host_state().host == Some(host)).then_some(())).await;

    let member = Identity::load_or_create(dirs[1].path()).unwrap();
    let community = Arc::new(CommunityState::load(&community_file).unwrap());
    let net = Net::bind(&member, tokio::sync::watch::channel(community).1, RelayChoice::Disabled).await.unwrap();
    let conn = net.connect_addr(node.endpoint_addr().await.unwrap(), net.ctl_alpn()).await.unwrap();
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    let hello = CtlMsg::Hello { member: member.member_id(), can_host: false, online_since_ms: 0 };
    write_msg(&mut send, &hello).await.unwrap();
    let back = conn.clone();
    tokio::spawn(async move {
        let _ = send_probe(&back).await;
    });
    // Heartbeat arrival times; Pings are answered so the host keeps the session.
    let (beat_tx, mut beat_rx) = tokio::sync::mpsc::unbounded_channel();
    let ctl = tokio::spawn(async move {
        while let Ok(Some(msg)) = read_msg(&mut recv).await {
            match msg {
                CtlMsg::Ping { nonce } => write_msg(&mut send, &CtlMsg::Pong { nonce }).await.unwrap(),
                CtlMsg::Heartbeat { .. } => beat_tx.send(Instant::now()).unwrap(),
                _ => {}
            }
        }
    });
    // About 2 MB/s, so the whole probe would take about 4 s.
    let probed = conn.clone();
    let probe = tokio::spawn(async move {
        let mut stream = probed.accept_uni().await.unwrap();
        let start = Instant::now();
        let mut buf = vec![0u8; 64 * 1024];
        let mut got: u64 = 0;
        while let Ok(Some(n)) = stream.read(&mut buf).await {
            got += n as u64;
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        (start, Instant::now(), got)
    });
    let (start, end, got) = tokio::time::timeout(Duration::from_secs(10), probe).await.expect("the probe ends").unwrap();
    // One more heartbeat after the probe, to close the last gap.
    tokio::time::sleep(Duration::from_millis(700)).await;
    ctl.abort();
    let beats: Vec<Instant> = std::iter::from_fn(|| beat_rx.try_recv().ok()).collect();
    let gaps: Vec<Duration> = beats.windows(2).filter(|w| w[1] > start && w[0] < end).map(|w| w[1] - w[0]).collect();
    let took = end - start;
    eprintln!("probe took {took:?} for {got} bytes; heartbeat gaps while it ran: {gaps:?}");
    assert!(gaps.len() >= 2, "too few heartbeats while the probe ran: {gaps:?}");
    let worst = gaps.iter().max().unwrap();
    assert!(*worst < Duration::from_secs(1), "a {worst:?} heartbeat gap while the host probed");
    assert!(got < PROBE_BYTES, "the slow member took the whole probe ({got} bytes in {took:?})");
    assert!(took < PROBE_MAX_TIME + Duration::from_millis(500), "the probe ran {took:?}");
}
