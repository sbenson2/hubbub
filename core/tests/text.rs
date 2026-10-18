//! Text channels with in-process nodes: FakeHost media, relays disabled.
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::FakeHost;
use hubbub_core::net::RelayChoice;
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use iroh::EndpointAddr;
use tokio::sync::broadcast;

/// One identity per entry in its own temp dir, and a community listing them all, saved in the
/// first dir. The dirs must outlive the nodes: each node stores its messages there.
fn community(can_host: &[bool]) -> (Vec<tempfile::TempDir>, CommunityState, PathBuf) {
    let dirs: Vec<tempfile::TempDir> = can_host.iter().map(|_| tempfile::tempdir().unwrap()).collect();
    let ids: Vec<Identity> = dirs.iter().map(|d| Identity::load_or_create(d.path()).unwrap()).collect();
    let names: Vec<String> = (0..ids.len()).map(|i| format!("node{i}")).collect();
    let members: Vec<(&Identity, &str, bool)> =
        ids.iter().zip(&names).zip(can_host).map(|((id, n), &h)| (id, n.as_str(), h)).collect();
    let community = CommunityState::for_tests("text", &members);
    let file = dirs[0].path().join("community.json");
    community.save_atomic(&file).unwrap();
    (dirs, community, file)
}

/// Starts a node and subscribes to its events at once.
async fn start(
    dir: &tempfile::TempDir,
    community_file: &Path,
    can_host: bool,
    peers: Vec<EndpointAddr>,
) -> (Node, broadcast::Receiver<NodeEvent>) {
    let cfg = NodeConfig {
        data_dir: dir.path().to_path_buf(),
        community_file: community_file.to_path_buf(),
        can_host,
        relay: RelayChoice::Disabled,
    };
    let node = Node::start_with_addrs(cfg, Box::new(FakeHost::new()), peers).await.unwrap();
    let rx = node.subscribe();
    (node, rx)
}

struct Cluster {
    nodes: Vec<Node>,
    events: Vec<broadcast::Receiver<NodeEvent>>,
    _dirs: Vec<tempfile::TempDir>,
}

/// Nodes sharing one community. Node i starts with the addresses of nodes 0..i.
async fn cluster(can_host: &[bool]) -> Cluster {
    let (dirs, _, file) = community(can_host);
    let (mut nodes, mut events, mut addrs) = (Vec::new(), Vec::new(), Vec::new());
    for (dir, &host) in dirs.iter().zip(can_host) {
        let (node, rx) = start(dir, &file, host, addrs.clone()).await;
        addrs.push(node.endpoint_addr().await.unwrap());
        nodes.push(node);
        events.push(rx);
    }
    Cluster { nodes, events, _dirs: dirs }
}

/// The host every node in `ns` names, when they all name the same one and it is one of them.
fn agreed_host(ns: &[Node]) -> Option<MemberId> {
    let host = ns.first()?.host_state().host?;
    let all_agree = ns.iter().all(|n| n.host_state().host == Some(host));
    let host_is_live = ns.iter().any(|n| n.member_id() == host);
    (all_agree && host_is_live).then_some(host)
}

async fn wait_agree(ns: &[Node], within: Duration) -> MemberId {
    let start = Instant::now();
    loop {
        if let Some(host) = agreed_host(ns) {
            return host;
        }
        let states: Vec<_> = ns.iter().map(|n| (n.member_id().tag(), n.host_state())).collect();
        assert!(start.elapsed() < within, "no agreed host within {within:?}: {states:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// A Text event's fields.
#[derive(Debug, PartialEq, Eq)]
struct Got {
    channel: String,
    term: u64,
    seq: u64,
    from: MemberId,
    body: String,
    client_id: u64,
}

/// The next `n` Text events on `rx`, skipping other events; panics after `within`.
async fn texts(rx: &mut broadcast::Receiver<NodeEvent>, n: usize, within: Duration, who: &str) -> Vec<Got> {
    let mut got = Vec::new();
    let collect = async {
        while got.len() < n {
            if let NodeEvent::Text { channel, term, seq, from, body, client_id, .. } = rx.recv().await.unwrap() {
                got.push(Got { channel, term, seq, from, body, client_id });
            }
        }
    };
    if tokio::time::timeout(within, collect).await.is_err() {
        panic!("{who} saw {} of {n} text messages within {within:?}: {got:?}", got.len());
    }
    got
}

/// Text events already queued on `rx`.
fn queued_texts(rx: &mut broadcast::Receiver<NodeEvent>) -> usize {
    std::iter::from_fn(|| rx.try_recv().ok()).filter(|e| matches!(e, NodeEvent::Text { .. })).count()
}

#[tokio::test]
async fn non_host_message_reaches_everyone_in_order() {
    let mut c = cluster(&[true; 3]).await;
    let host = wait_agree(&c.nodes, Duration::from_secs(4)).await;
    let term = c.nodes[0].host_state().term;
    let sender = c.nodes.iter().position(|n| n.member_id() != host).unwrap();
    let from = c.nodes[sender].member_id();
    let mut client_ids = Vec::new();
    for body in ["one", "two", "three"] {
        client_ids.push(c.nodes[sender].send_text("general", body).await.unwrap());
    }
    let want: Vec<Got> = ["one", "two", "three"]
        .iter()
        .zip(&client_ids)
        .enumerate()
        .map(|(i, (body, &client_id))| Got {
            channel: "general".into(),
            term,
            seq: i as u64 + 1,
            from,
            body: body.to_string(),
            client_id,
        })
        .collect();
    for (i, rx) in c.events.iter_mut().enumerate() {
        let who = if c.nodes[i].member_id() == host { "the host" } else { "a member" };
        assert_eq!(texts(rx, 3, Duration::from_secs(5), who).await, want, "node {i}");
        let stored = c.nodes[i].text_history("general", 10).unwrap();
        let stored: Vec<_> = stored.iter().map(|m| (m.term, m.seq, m.from, m.body.as_str())).collect();
        assert_eq!(stored, [(term, 1, from, "one"), (term, 2, from, "two"), (term, 3, from, "three")], "node {i}");
    }
}

#[tokio::test]
async fn message_sent_without_a_host_is_delivered_after_one_appears() {
    let (dirs, _, file) = community(&[false, true]);
    // A phone alone: nobody online can host.
    let (phone, mut phone_rx) = start(&dirs[0], &file, false, vec![]).await;
    let client_id = phone.send_text("general", "anyone there?").await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(phone.host_state().host, None);
    assert_eq!(queued_texts(&mut phone_rx), 0, "nothing is delivered without a host");
    assert!(phone.text_history("general", 10).unwrap().is_empty());

    let (desktop, mut desktop_rx) = start(&dirs[1], &file, true, vec![phone.endpoint_addr().await.unwrap()]).await;
    let nodes = [phone, desktop];
    assert_eq!(wait_agree(&nodes, Duration::from_secs(5)).await, nodes[1].member_id());
    let want = Got {
        channel: "general".into(),
        term: nodes[1].host_state().term,
        seq: 1,
        from: nodes[0].member_id(),
        body: "anyone there?".into(),
        client_id,
    };
    assert_eq!(texts(&mut phone_rx, 1, Duration::from_secs(5), "the phone").await, [want]);
    let at_desktop = texts(&mut desktop_rx, 1, Duration::from_secs(5), "the desktop").await;
    assert_eq!((at_desktop[0].from, at_desktop[0].client_id), (nodes[0].member_id(), client_id));
    assert_eq!(nodes[0].text_history("general", 10).unwrap().len(), 1);
}

#[tokio::test]
async fn after_handover_new_messages_use_the_higher_term() {
    let mut c = cluster(&[true; 3]).await;
    let old_host = wait_agree(&c.nodes, Duration::from_secs(4)).await;
    let old_term = c.nodes[0].host_state().term;
    let sender = c.nodes.iter().position(|n| n.member_id() != old_host).unwrap();
    let watcher = c.nodes.iter().rposition(|n| n.member_id() != old_host).unwrap();
    assert_ne!(sender, watcher);
    c.nodes[sender].send_text("general", "before").await.unwrap();
    let before = texts(&mut c.events[watcher], 1, Duration::from_secs(5), "the watcher").await;
    assert_eq!((before[0].term, before[0].seq), (old_term, 1));

    // Hard kill: drop the host without a Resign.
    let h = c.nodes.iter().position(|n| n.member_id() == old_host).unwrap();
    drop(c.nodes.remove(h));
    c.events.remove(h);
    let (sender, watcher) = (sender - usize::from(h < sender), watcher - usize::from(h < watcher));
    let new_host = wait_agree(&c.nodes, Duration::from_secs(5)).await;
    let new_term = c.nodes[0].host_state().term;
    assert_ne!(new_host, old_host);
    assert!(new_term > old_term, "{new_term} > {old_term}");

    c.nodes[sender].send_text("general", "after").await.unwrap();
    let after = texts(&mut c.events[watcher], 1, Duration::from_secs(5), "the watcher").await;
    assert_eq!((after[0].term, after[0].seq, after[0].body.as_str()), (new_term, 1, "after"));
    let stored: Vec<_> = c.nodes[watcher]
        .text_history("general", 10)
        .unwrap()
        .into_iter()
        .map(|m| (m.term, m.seq, m.body))
        .collect();
    assert_eq!(stored, [(old_term, 1, "before".to_string()), (new_term, 1, "after".to_string())]);
}

#[tokio::test]
async fn host_relays_without_decrypting() {
    // The host's copy of the community has another secret. Membership goes by member id, so
    // it still connects and hosts, but it cannot open a single message.
    let (dirs, community, file) = community(&[true, false, false]);
    let mut blind = community.clone();
    blind.secret_hex = CommunityState::create("other", &Identity::from_secret_bytes([9; 32]), true).secret_hex;
    let blind_file = dirs[0].path().join("blind.json");
    blind.save_atomic(&blind_file).unwrap();
    let (host, mut host_rx) = start(&dirs[0], &blind_file, true, vec![]).await;
    let host_addr = host.endpoint_addr().await.unwrap();
    let (b, mut b_rx) = start(&dirs[1], &file, false, vec![host_addr.clone()]).await;
    let (c, mut c_rx) = start(&dirs[2], &file, false, vec![host_addr]).await;
    let nodes = [host, b, c];
    assert_eq!(wait_agree(&nodes, Duration::from_secs(4)).await, nodes[0].member_id());

    let client_id = nodes[1].send_text("general", "only members can read this").await.unwrap();
    let want = Got {
        channel: "general".into(),
        term: nodes[0].host_state().term,
        seq: 1,
        from: nodes[1].member_id(),
        body: "only members can read this".into(),
        client_id,
    };
    assert_eq!(texts(&mut c_rx, 1, Duration::from_secs(5), "the other phone").await, [want]);
    assert_eq!(texts(&mut b_rx, 1, Duration::from_secs(5), "the sender").await.len(), 1);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(queued_texts(&mut host_rx), 0, "the host could not open what it relayed");
    assert!(nodes[0].text_history("general", 10).unwrap().is_empty());
}

#[tokio::test]
async fn a_delivery_lost_with_the_senders_session_comes_back_once_in_the_same_term() {
    let (dirs, _, file) = community(&[true, false, false]);
    let (host, mut host_rx) = start(&dirs[0], &file, true, vec![]).await;
    let host_addr = host.endpoint_addr().await.unwrap();
    let (phone, mut phone_rx) = start(&dirs[1], &file, false, vec![host_addr.clone()]).await;
    let (watcher, mut watcher_rx) = start(&dirs[2], &file, false, vec![host_addr]).await;
    let nodes = [host, phone, watcher];
    let host = wait_agree(&nodes, Duration::from_secs(4)).await;
    assert_eq!(host, nodes[0].member_id());
    let term = nodes[0].host_state().term;

    // The phone's only session to the host ends as its own delivery arrives, unread. The host
    // has ordered the message and the watcher has it.
    nodes[1].lose_next_own_text_delivery();
    let client_id = nodes[1].send_text("general", "did it go?").await.unwrap();
    let want = Got {
        channel: "general".into(),
        term,
        seq: 1,
        from: nodes[1].member_id(),
        body: "did it go?".into(),
        client_id,
    };
    assert_eq!(texts(&mut watcher_rx, 1, Duration::from_secs(5), "the watcher").await, std::slice::from_ref(&want));
    assert_eq!(texts(&mut host_rx, 1, Duration::from_secs(5), "the host").await, std::slice::from_ref(&want));

    // The phone redials and resubmits; the host sends the original delivery back.
    let (mut lost_session, mut got) = (false, Vec::new());
    let sender_sees_it = async {
        while got.is_empty() {
            match phone_rx.recv().await.unwrap() {
                NodeEvent::PeerDown { member } if member == host => lost_session = true,
                NodeEvent::Text { channel, term, seq, from, body, client_id, .. } => {
                    got.push(Got { channel, term, seq, from, body, client_id })
                }
                _ => {}
            }
        }
    };
    let in_time = tokio::time::timeout(Duration::from_secs(8), sender_sees_it).await.is_ok();
    assert!(lost_session, "the phone's session to the host never dropped");
    assert!(in_time, "the sender never saw its own message after redialing");
    assert_eq!(got, [want]);
    assert_eq!(nodes[0].host_state().term, term, "no hand-over: the same term");

    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(queued_texts(&mut phone_rx), 0, "the sender saw it once");
    assert_eq!(queued_texts(&mut watcher_rx), 0, "the watcher saw it once");
    assert_eq!(queued_texts(&mut host_rx), 0, "the host saw it once");
    for (i, n) in nodes.iter().enumerate() {
        assert_eq!(n.text_history("general", 10).unwrap().len(), 1, "node {i} stored it once");
    }
}
