//! Text channels with in-process nodes: FakeHost media, relays disabled.
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::FakeHost;
use hubbub_core::net::{Net, RelayChoice};
use hubbub_core::proto::{read_msg, write_json, write_msg, CtlMsg};
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

/// Node 0 is dialled by every other node; those do not know each other.
async fn star_cluster(n: usize) -> Cluster {
    let (dirs, _, file) = community(&vec![true; n]);
    let (first, first_rx) = start(&dirs[0], &file, true, vec![]).await;
    let hub = first.endpoint_addr().await.unwrap();
    let (mut nodes, mut events) = (vec![first], vec![first_rx]);
    // The hub must be host before anyone else starts: a leaf only sees the hub, so a leaf host would never meet another.
    wait_agree(&nodes, Duration::from_secs(20)).await;
    for dir in &dirs[1..] {
        let (node, rx) = start(dir, &file, true, vec![hub.clone()]).await;
        nodes.push(node);
        events.push(rx);
        // One at a time: nodes that start together under load can each elect themselves.
        wait_agree(&nodes, Duration::from_secs(20)).await;
    }
    Cluster { nodes, events, _dirs: dirs }
}

/// One round of the split-brain scenario: in a star of `survivors + 1` nodes the host leaves
/// (gracefully or not), the survivors learn each other's addresses, and each texts at once.
/// Every survivor must get every text, once. Returns a description of any failure.
async fn host_leaves_then_survivors_text(graceful: bool, survivors: usize) -> Result<(), String> {
    let mut c = star_cluster(survivors + 1).await;
    let old_host = wait_agree(&c.nodes, Duration::from_secs(20)).await;
    let h = c.nodes.iter().position(|n| n.member_id() == old_host).unwrap();
    let gone = c.nodes.remove(h);
    c.events.remove(h);
    if graceful {
        gone.shutdown().await;
    } else {
        drop(gone);
    }
    // The survivors only now learn each other's addresses (they met through the host).
    let addrs = futures_addrs(&c.nodes).await;
    for (i, n) in c.nodes.iter().enumerate() {
        addrs.iter().enumerate().filter(|(j, _)| *j != i).for_each(|(_, a)| n.add_peer_addr(a.clone()));
    }
    let mut sent = Vec::new();
    for (i, n) in c.nodes.iter().enumerate() {
        sent.push((n.member_id(), n.send_text("general", &format!("from {i}")).await.unwrap()));
    }
    for (i, rx) in c.events.iter_mut().enumerate() {


        // Everyone's own text is shown too: wait for all of them.
        let mut want: Vec<_> = sent.iter().collect();
        let got = tokio::time::timeout(Duration::from_secs(12), async {
            while !want.is_empty() {
                if let NodeEvent::Text { from, client_id, .. } = rx.recv().await.unwrap() {
                    want.retain(|(m, id)| !(*m == from && *id == client_id));
                }
            }
        })
        .await;
        if got.is_err() {
            let hist = histories(&c.nodes);
            return Err(format!("survivor {i} lacks {} texts (graceful={graceful}, survivors={survivors}): history={hist:?}", want.len()));
        }
    }
    // Let stragglers land, then every history is the same set of (from, client_id), no repeats.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut sets = Vec::new();
    for n in &c.nodes {
        let mut keys: Vec<_> =
            n.text_history("general", 50).unwrap().iter().map(|m| (m.from.0, m.client_id)).collect();
        let n_all = keys.len();
        keys.sort();
        keys.dedup();
        if keys.len() != n_all {
            return Err(format!("duplicates in a history: {:?}", histories(&c.nodes)));
        }
        sets.push(keys);
    }
    if sets.iter().any(|k| *k != sets[0]) {
        return Err(format!("histories differ: {:?}", histories(&c.nodes)));
    }
    Ok(())
}

async fn futures_addrs(ns: &[Node]) -> Vec<EndpointAddr> {
    let mut v = Vec::new();
    for n in ns {
        v.push(n.endpoint_addr().await.unwrap());
    }
    v
}

fn histories(ns: &[Node]) -> Vec<Vec<(u64, u64, String)>> {
    ns.iter()
        .map(|n| n.text_history("general", 50).unwrap().iter().map(|m| (m.term, m.seq, m.body.clone())).collect())
        .collect()
}

/// `SPLIT_ITERS` (default 2) sets how many times each of the four variants runs.
#[tokio::test]
async fn survivors_can_text_after_the_host_leaves() {
    let n: usize = std::env::var("SPLIT_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(2);
    let mut fails = Vec::new();
    for i in 0..n {
        for graceful in [true, false] {
            for survivors in [2, 3] {
                if let Err(e) = host_leaves_then_survivors_text(graceful, survivors).await {
                    fails.push(format!("iter {i}: {e}"));
                }
            }
        }
    }
    assert!(fails.is_empty(), "{} of {} rounds failed:\n{}", fails.len(), n * 4, fails.join("\n"));
}

/// The third-member case. After the host leaves, survivors 0 and 1 find each other and agree
/// on a host while survivor 2 elects itself alone. A text from the non-host of the pair is
/// ordered by the pair's host. Then all three meet: whichever host loses the tie must not
/// strand that text, and survivor 2 must get it.
async fn staged_split(graceful: bool) -> Result<(), String> {
    let mut c = star_cluster(4).await;
    let old_host = wait_agree(&c.nodes, Duration::from_secs(20)).await;
    let h = c.nodes.iter().position(|n| n.member_id() == old_host).unwrap();
    let gone = c.nodes.remove(h);
    c.events.remove(h);
    if graceful {
        gone.shutdown().await;
    } else {
        drop(gone);
    }
    let addrs = futures_addrs(&c.nodes).await;
    c.nodes[0].add_peer_addr(addrs[1].clone());
    c.nodes[1].add_peer_addr(addrs[0].clone());
    let pair_host = wait_agree(&c.nodes[..2], Duration::from_secs(12)).await;
    let lone = c.nodes[2].member_id();
    let deadline = Instant::now() + Duration::from_secs(12);
    while c.nodes[2].host_state().host != Some(lone) {
        if Instant::now() > deadline {
            return Err("the lone survivor never elected itself".into());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let sender = if c.nodes[0].member_id() == pair_host { 1 } else { 0 };
    let from = c.nodes[sender].member_id();
    let id = c.nodes[sender].send_text("general", "ordered by the pair's host").await.unwrap();
    let pair_got = tokio::time::timeout(Duration::from_secs(5), async {
        for i in [0usize, 1] {
            loop {
                if let NodeEvent::Text { client_id, .. } = c.events[i].recv().await.unwrap() {
                    if client_id == id {
                        break;
                    }
                }
            }
        }
    })
    .await;
    if pair_got.is_err() {
        return Err("the pair did not get it".into());
    }
    for (i, n) in c.nodes.iter().enumerate() {
        addrs.iter().enumerate().filter(|(j, _)| *j != i).for_each(|(_, a)| n.add_peer_addr(a.clone()));
    }
    let got = tokio::time::timeout(Duration::from_secs(12), async {
        loop {
            if let NodeEvent::Text { from: f, client_id, .. } = c.events[2].recv().await.unwrap() {
                if f == from && client_id == id {
                    return;
                }
            }
        }
    })
    .await;
    if got.is_err() {
        return Err(format!("the lone survivor never got it (graceful={graceful}, pair host was node {}): {:?}",
            1 - sender, histories(&c.nodes)));
    }
    Ok(())
}

#[tokio::test]
async fn a_text_ordered_by_a_losing_host_reaches_the_third_member() {
    let n: usize = std::env::var("SPLIT_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(2);
    let mut fails = Vec::new();
    for i in 0..n {
        for graceful in [true, false] {
            if let Err(e) = staged_split(graceful).await {
                fails.push(format!("iter {i}: {e}"));
            }
        }
    }
    assert!(fails.is_empty(), "{} of {} rounds failed:\n{}", fails.len(), n * 2, fails.join("\n"));
}

#[tokio::test]
async fn a_member_added_later_never_sees_earlier_messages() {
    let (dirs, _, file) = community(&[true, false, false]);
    let (host, _host_rx) = start(&dirs[0], &file, true, vec![]).await;
    let addr = host.endpoint_addr().await.unwrap();
    let (early, mut early_rx) = start(&dirs[1], &file, false, vec![addr.clone()]).await;
    let nodes = [host, early];
    assert_eq!(wait_agree(&nodes, Duration::from_secs(5)).await, nodes[0].member_id());
    let host = &nodes[0];
    for body in ["A", "B"] {
        host.send_text("general", body).await.unwrap();
    }
    texts(&mut early_rx, 2, Duration::from_secs(5), "the early member").await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // The third member runs this community for the first time now.
    let (late, mut late_rx) = start(&dirs[2], &file, false, vec![addr]).await;
    tokio::time::sleep(Duration::from_millis(2500)).await;
    assert_eq!(queued_texts(&mut late_rx), 0, "nothing from before it was added");
    assert!(late.text_history("general", 10).unwrap().is_empty());
    host.send_text("general", "C").await.unwrap();
    let got = texts(&mut late_rx, 1, Duration::from_secs(5), "the late member").await;
    assert_eq!(got[0].body, "C");
    assert_eq!(late.text_history("general", 10).unwrap().len(), 1);
}

#[tokio::test]
async fn a_member_that_comes_back_gets_what_it_missed_once_and_in_order() {
    let (dirs, _, file) = community(&[true, false]);
    let (host, _host_rx) = start(&dirs[0], &file, true, vec![]).await;
    let addr = host.endpoint_addr().await.unwrap();
    let (phone, mut phone_rx) = start(&dirs[1], &file, false, vec![addr.clone()]).await;
    let mut nodes = vec![host, phone];
    wait_agree(&nodes, Duration::from_secs(5)).await;
    let phone = nodes.pop().unwrap();
    let host = nodes.pop().unwrap();
    for body in ["A", "B"] {
        host.send_text("general", body).await.unwrap();
    }
    texts(&mut phone_rx, 2, Duration::from_secs(5), "the phone").await;
    phone.shutdown().await;
    for i in 0..10 {
        host.send_text("general", &format!("missed {i}")).await.unwrap();
    }
    let (phone, mut phone_rx) = start(&dirs[1], &file, false, vec![addr]).await;
    // Live messages race the catch-up.
    for i in 0..10 {
        host.send_text("general", &format!("live {i}")).await.unwrap();
    }
    let got = texts(&mut phone_rx, 20, Duration::from_secs(8), "the phone").await;
    let seqs: Vec<u64> = got.iter().map(|g| g.seq).collect();
    assert_eq!(seqs, (3..=22).collect::<Vec<u64>>(), "only what it missed, in order: {got:?}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(queued_texts(&mut phone_rx), 0);
    let stored: Vec<u64> = phone.text_history("general", 50).unwrap().iter().map(|m| m.seq).collect();
    assert_eq!(stored, (1..=22).collect::<Vec<u64>>());
}

/// A hand-driven member: a bare `Net` that dials `node`'s control ALPN, says Hello, and returns
/// the streams, with `node`'s own Hello already read.
async fn raw_member(
    node: &Node,
    dir: &tempfile::TempDir,
    community_file: &Path,
) -> (Net, iroh::endpoint::SendStream, iroh::endpoint::RecvStream) {
    let me = Identity::load_or_create(dir.path()).unwrap();
    let community = std::sync::Arc::new(CommunityState::load(community_file).unwrap());
    let net = Net::bind(&me, tokio::sync::watch::channel(community).1, RelayChoice::Disabled).await.unwrap();
    let conn = net.connect_addr(node.endpoint_addr().await.unwrap(), net.ctl_alpn()).await.unwrap();
    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    write_msg(&mut send, &CtlMsg::Hello { member: me.member_id(), can_host: false, online_since_ms: 0, proto: 2 }).await.unwrap();
    let hello = read_msg(&mut recv).await.unwrap();
    assert!(matches!(hello, Some(CtlMsg::Hello { .. })), "{hello:?}");
    // Keep the connection alive for the caller.
    std::mem::forget(conn);
    (net, send, recv)
}

#[tokio::test]
async fn an_unknown_message_does_not_end_the_session() {
    let (dirs, _, file) = community(&[true, false]);
    let (host, _rx) = start(&dirs[0], &file, true, vec![]).await;
    let (_net, mut send, mut recv) = raw_member(&host, &dirs[1], &file).await;
    // A message from a future build, then a Ping: the session must still answer.
    write_json(&mut send, &serde_json::json!({"t": "FromTheFuture", "x": [1, 2, 3]})).await.unwrap();
    write_msg(&mut send, &CtlMsg::Ping { nonce: 77 }).await.unwrap();
    let pong = tokio::time::timeout(Duration::from_secs(5), async {
        while let Ok(Some(msg)) = read_msg(&mut recv).await {
            if msg == (CtlMsg::Pong { nonce: 77 }) {
                return true;
            }
        }
        false
    })
    .await;
    assert_eq!(pong, Ok(true), "the node dropped the session or never answered");
}

#[tokio::test]
async fn a_repeated_text_have_is_answered_only_once() {
    let (dirs, _, file) = community(&[true, false]);
    let (host, _rx) = start(&dirs[0], &file, true, vec![]).await;
    wait_agree(std::slice::from_ref(&host), Duration::from_secs(5)).await;
    for body in ["one", "two"] {
        host.send_text("general", body).await.unwrap();
    }
    let (_net, mut send, mut recv) = raw_member(&host, &dirs[1], &file).await;
    for _ in 0..3 {
        write_msg(&mut send, &CtlMsg::TextHave { since_ms: 0, have: vec![] }).await.unwrap();
    }
    // Count the history deliveries over a few seconds, answering pings so the session lives.
    let mut delivered = 0;
    let _ = tokio::time::timeout(Duration::from_secs(3), async {
        while let Ok(Some(msg)) = read_msg(&mut recv).await {
            match msg {
                CtlMsg::Ping { nonce } => write_msg(&mut send, &CtlMsg::Pong { nonce }).await.unwrap(),
                CtlMsg::TextDeliver { .. } => delivered += 1,
                _ => {}
            }
        }
    })
    .await;
    assert_eq!(delivered, 2, "the backlog must be sent once, not once per TextHave");
}

#[tokio::test]
async fn a_peer_that_never_sends_text_have_still_gets_live_text() {
    let (dirs, _, file) = community(&[true, false]);
    let (host, _rx) = start(&dirs[0], &file, true, vec![]).await;
    wait_agree(std::slice::from_ref(&host), Duration::from_secs(5)).await;
    let (_net, mut send, mut recv) = raw_member(&host, &dirs[1], &file).await;
    // Past the wait for a TextHave that never comes.
    tokio::time::sleep(Duration::from_millis(2500)).await;
    write_msg(&mut send, &CtlMsg::TextSubmit { channel: "general".into(), client_id: 5, ciphertext: vec![1, 2, 3] })
        .await
        .unwrap();
    let delivered = tokio::time::timeout(Duration::from_secs(8), async {
        while let Ok(Some(msg)) = read_msg(&mut recv).await {
            match msg {
                CtlMsg::Ping { nonce } => write_msg(&mut send, &CtlMsg::Pong { nonce }).await.unwrap(),
                CtlMsg::TextDeliver { client_id: 5, .. } => return true,
                _ => {}
            }
        }
        false
    })
    .await;
    assert_eq!(delivered, Ok(true), "live text never reached a peer that sent no TextHave");
}

#[tokio::test]
async fn a_device_invited_again_does_not_get_the_messages_sent_while_it_was_out() {
    let (dirs, _, file) = community(&[true, false]);
    let (host, _host_rx) = start(&dirs[0], &file, true, vec![]).await;
    let addr = host.endpoint_addr().await.unwrap();
    let (phone, mut phone_rx) = start(&dirs[1], &file, false, vec![addr.clone()]).await;
    let mut nodes = vec![host, phone];
    wait_agree(&nodes, Duration::from_secs(5)).await;
    let phone = nodes.pop().unwrap();
    let host = nodes.pop().unwrap();
    host.send_text("general", "before").await.unwrap();
    texts(&mut phone_rx, 1, Duration::from_secs(5), "the phone").await;
    // Removed: the device is gone while the gap is sent.
    phone.shutdown().await;
    host.send_text("general", "gap 1").await.unwrap();
    host.send_text("general", "gap 2").await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    // Invited again on the same data dir: the hub marks the join, as `Hub::join` does.
    hubbub_core::text::mark_joined(dirs[1].path());
    let (phone, mut phone_rx) = start(&dirs[1], &file, false, vec![addr]).await;
    tokio::time::sleep(Duration::from_millis(2500)).await;
    assert_eq!(queued_texts(&mut phone_rx), 0, "nothing from the gap");
    host.send_text("general", "after").await.unwrap();
    let got = texts(&mut phone_rx, 1, Duration::from_secs(5), "the phone").await;
    assert_eq!(got[0].body, "after");
    let bodies: Vec<_> = phone.text_history("general", 10).unwrap().into_iter().map(|m| m.body).collect();
    assert_eq!(bodies, ["before", "after"]);
}
