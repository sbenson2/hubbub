//! Voice presence with in-process nodes: FakeHost media, relays disabled.
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::FakeHost;
use hubbub_core::net::RelayChoice;
use hubbub_core::proto::VoicePresence;
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

/// Node 0 is dialled by every other node; those do not know each other.
async fn star_cluster(n: usize) -> Cluster {
    star_cluster_of(&vec![true; n]).await
}

/// A star whose members may or may not host; the first (the hub) must.
async fn star_cluster_of(can_host: &[bool]) -> Cluster {
    let (dirs, _, file) = community(can_host);
    let (first, first_rx) = start(&dirs[0], &file, true, vec![]).await;
    let hub = first.endpoint_addr().await.unwrap();
    let (mut nodes, mut events) = (vec![first], vec![first_rx]);
    // The hub must be host before anyone else starts: a leaf only sees the hub, so a leaf host would never meet another.
    wait_agree(&nodes, Duration::from_secs(20)).await;
    for (dir, &host) in dirs[1..].iter().zip(&can_host[1..]) {
        let (node, rx) = start(dir, &file, host, vec![hub.clone()]).await;
        nodes.push(node);
        events.push(rx);
        // One at a time: nodes that start together under load can each elect themselves.
        wait_agree(&nodes, Duration::from_secs(20)).await;
    }
    Cluster { nodes, events, _dirs: dirs }
}


fn me(n: &Node) -> MemberId {
    n.member_id()
}

fn entry(n: &Node, channel: &str, muted: bool, deafened: bool) -> VoicePresence {
    VoicePresence { member: n.member_id(), channel: channel.into(), muted, deafened }
}

/// Polls `node.voice_roster()` until it equals `want` (order ignored); panics after `within`.
async fn roster_is(node: &Node, want: &[VoicePresence], within: Duration, who: &str) {
    let mut want: Vec<VoicePresence> = want.to_vec();
    want.sort_by(|a, b| (&a.channel, a.member).cmp(&(&b.channel, b.member)));
    let start = Instant::now();
    loop {
        let mut got = node.voice_roster();
        got.sort_by(|a, b| (&a.channel, a.member).cmp(&(&b.channel, b.member)));
        if got == want {
            return;
        }
        assert!(start.elapsed() < within, "{who}: roster {got:?}, wanted {want:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

const WITHIN: Duration = Duration::from_secs(8);

#[tokio::test]
async fn mesh_member_joining_voice_shows_to_everyone_and_emits_an_event() {
    let mut c = cluster(&[true; 3]).await;
    wait_agree(&c.nodes, Duration::from_secs(4)).await;
    c.nodes[0].set_voice(Some("lobby".into()), false, false);
    let want = [entry(&c.nodes[0], "lobby", false, false)];
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("node {i}")).await;
    }
    // B and C each saw a snapshot event that lists A.
    for i in [1, 2] {
        let got = tokio::time::timeout(WITHIN, async {
            loop {
                if let NodeEvent::VoiceRoster { entries } = c.events[i].recv().await.unwrap() {
                    if entries == want {
                        return;
                    }
                }
            }
        })
        .await;
        assert!(got.is_ok(), "node {i} never got a VoiceRoster event with node 0");
    }
}

#[tokio::test]
async fn star_leaf_voice_reaches_the_other_leaf() {
    let c = star_cluster(3).await;
    wait_agree(&c.nodes, Duration::from_secs(20)).await;
    c.nodes[1].set_voice(Some("lobby".into()), true, false);
    let want = [entry(&c.nodes[1], "lobby", true, false)];
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("node {i}")).await;
    }
    // The other leaf joins too: both leaves and the hub list both.
    c.nodes[2].set_voice(Some("lobby".into()), false, false);
    let want = [entry(&c.nodes[1], "lobby", true, false), entry(&c.nodes[2], "lobby", false, false)];
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("node {i}")).await;
    }
}

#[tokio::test]
async fn late_starter_gets_the_roster() {
    let (dirs, _, file) = community(&[true; 3]);
    let (a, _) = start(&dirs[0], &file, true, vec![]).await;
    let (b, _) = start(&dirs[1], &file, true, vec![a.endpoint_addr().await.unwrap()]).await;
    let (a, b) = {
        let pair = vec![a, b];
        wait_agree(&pair, Duration::from_secs(10)).await;
        let mut it = pair.into_iter();
        (it.next().unwrap(), it.next().unwrap())
    };
    a.set_voice(Some("lobby".into()), false, true);
    b.set_voice(Some("lobby".into()), false, false);
    let want = [entry(&a, "lobby", false, true), entry(&b, "lobby", false, false)];
    roster_is(&a, &want, WITHIN, "a").await;
    let (c, _) =
        start(&dirs[2], &file, true, vec![a.endpoint_addr().await.unwrap(), b.endpoint_addr().await.unwrap()]).await;
    roster_is(&c, &want, WITHIN, "late c").await;
}

#[tokio::test]
async fn node_dropped_without_goodbye_leaves_the_roster() {
    let mut c = star_cluster(3).await;
    let host = wait_agree(&c.nodes, Duration::from_secs(20)).await;
    assert_eq!(host, me(&c.nodes[0]), "the hub hosts");
    let leaf = 1;
    c.nodes[0].set_voice(Some("lobby".into()), false, false);
    c.nodes[leaf].set_voice(Some("lobby".into()), false, false);
    let both = [entry(&c.nodes[0], "lobby", false, false), entry(&c.nodes[leaf], "lobby", false, false)];
    for n in &c.nodes {
        roster_is(n, &both, WITHIN, "before drop").await;
    }
    let gone = c.nodes.remove(leaf);
    drop(gone);
    let want = [entry(&c.nodes[0], "lobby", false, false)];
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("survivor {i}")).await;
    }
}

#[tokio::test]
async fn roster_survives_a_host_handover() {
    let mut c = cluster(&[true; 3]).await;
    let host = wait_agree(&c.nodes, Duration::from_secs(4)).await;
    // The two members that are not the host join voice; then the host (also in voice) dies.
    for n in &c.nodes {
        n.set_voice(Some("lobby".into()), me(n) == host, false);
    }
    let all: Vec<VoicePresence> = c.nodes.iter().map(|n| entry(n, "lobby", me(n) == host, false)).collect();
    for n in &c.nodes {
        roster_is(n, &all, WITHIN, "before handover").await;
    }
    let h = c.nodes.iter().position(|n| me(n) == host).unwrap();
    drop(c.nodes.remove(h));
    let want: Vec<VoicePresence> = c.nodes.iter().map(|n| entry(n, "lobby", false, false)).collect();
    wait_agree(&c.nodes, Duration::from_secs(10)).await;
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("survivor {i}")).await;
    }
    // The new host's roster is the one in force: a later change still propagates.
    c.nodes[0].set_voice(None, false, false);
    let want = [entry(&c.nodes[1], "lobby", false, false)];
    for (i, n) in c.nodes.iter().enumerate() {
        roster_is(n, &want, WITHIN, &format!("survivor {i} after leave")).await;
    }
}

#[tokio::test]
async fn mute_deafen_and_leave_updates_arrive() {
    let c = star_cluster(3).await;
    wait_agree(&c.nodes, Duration::from_secs(20)).await;
    let leaf = &c.nodes[1];
    leaf.set_voice(Some("lobby".into()), false, false);
    roster_is(&c.nodes[2], &[entry(leaf, "lobby", false, false)], WITHIN, "joined").await;
    leaf.set_voice(Some("lobby".into()), true, false);
    roster_is(&c.nodes[2], &[entry(leaf, "lobby", true, false)], WITHIN, "muted").await;
    leaf.set_voice(Some("lobby".into()), true, true);
    roster_is(&c.nodes[2], &[entry(leaf, "lobby", true, true)], WITHIN, "deafened").await;
    leaf.set_voice(None, false, false);
    roster_is(&c.nodes[2], &[], WITHIN, "left").await;
    roster_is(&c.nodes[0], &[], WITHIN, "left (hub)").await;
}

#[tokio::test]
async fn unknown_voice_channel_is_ignored() {
    let c = cluster(&[true; 2]).await;
    wait_agree(&c.nodes, Duration::from_secs(4)).await;
    c.nodes[0].set_voice(Some("nope".into()), false, false);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(c.nodes[0].voice_roster().is_empty());
    assert!(c.nodes[1].voice_roster().is_empty());
}

#[tokio::test]
async fn star_leaf_drops_the_dead_hub_and_stale_rows() {
    let mut c = star_cluster_of(&[true, false, false]).await;
    let host = wait_agree(&c.nodes, Duration::from_secs(20)).await;
    assert_eq!(host, me(&c.nodes[0]), "the hub hosts");
    for n in &c.nodes {
        n.set_voice(Some("lobby".into()), false, false);
    }
    let all: Vec<VoicePresence> = c.nodes.iter().map(|n| entry(n, "lobby", false, false)).collect();
    for n in &c.nodes {
        roster_is(n, &all, WITHIN, "before crash").await;
    }
    drop(c.nodes.remove(0));
    // The hub's own row goes at once; the other leaf is not a direct peer, so it goes after the grace.
    let leaf = &c.nodes[0];
    let start = Instant::now();
    loop {
        if !leaf.voice_roster().iter().any(|e| e.member == host) {
            break;
        }
        assert!(start.elapsed() < WITHIN, "dead hub still shown: {:?}", leaf.voice_roster());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    roster_is(leaf, &[entry(leaf, "lobby", false, false)], Duration::from_secs(20), "after grace").await;
}
