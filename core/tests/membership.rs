//! Live membership with in-process nodes: FakeHost media, relays disabled. Each node has its
//! own community file, because nodes now save the state they merge.
use std::path::PathBuf;
use std::time::{Duration, Instant};

use hubbub_core::community::{CommunityState, NewMember};
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::FakeHost;
use hubbub_core::net::RelayChoice;
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use iroh::EndpointAddr;
use tokio::sync::broadcast;

struct Peer {
    dir: tempfile::TempDir,
    id: Identity,
}

fn peers(n: usize) -> Vec<Peer> {
    (0..n)
        .map(|_| {
            let dir = tempfile::tempdir().unwrap();
            let id = Identity::load_or_create(dir.path()).unwrap();
            Peer { dir, id }
        })
        .collect()
}

fn new_member(p: &Peer, name: &str) -> NewMember {
    NewMember { id: p.id.member_id(), name: name.into(), can_host: true, door: p.id.door_id(), via_invite: None }
}

fn file(p: &Peer) -> PathBuf {
    p.dir.path().join("community.json")
}

/// Starts `p` with `state` saved in its own dir, dialing `addrs`.
async fn start(p: &Peer, state: &CommunityState, addrs: Vec<EndpointAddr>) -> (Node, broadcast::Receiver<NodeEvent>, EndpointAddr) {
    state.save_atomic(&file(p)).unwrap();
    let cfg = NodeConfig {
        data_dir: p.dir.path().to_path_buf(),
        community_file: file(p),
        can_host: true,
        relay: RelayChoice::Disabled,
    };
    let node = Node::start_with_addrs(cfg, Box::new(FakeHost::new()), addrs).await.unwrap();
    let rx = node.subscribe();
    let addr = node.endpoint_addr().await.unwrap();
    (node, rx, addr)
}

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

fn member_ids(n: &Node) -> Vec<MemberId> {
    let mut ids: Vec<MemberId> = n.members().into_iter().map(|(m, _)| m).collect();
    ids.sort();
    ids
}

/// `MembersChanged` events waiting in `rx`.
fn changes(rx: &mut broadcast::Receiver<NodeEvent>) -> usize {
    let mut n = 0;
    while let Ok(e) = rx.try_recv() {
        n += matches!(e, NodeEvent::MembersChanged) as usize;
    }
    n
}

#[tokio::test]
async fn a_member_admitted_at_runtime_is_dialed_and_connects_without_a_restart() {
    let p = peers(3);
    let base = CommunityState::for_tests("live", &[(&p[0].id, "a", true), (&p[1].id, "b", true)]);
    // c's own copy already lists c; a and b only learn of c when a admits it.
    let mut with_c = base.clone();
    with_c.admit(&p[0].id, new_member(&p[2], "c")).unwrap();

    let (a, mut a_events, a_addr) = start(&p[0], &base, vec![]).await;
    let (b, mut b_events, _) = start(&p[1], &base, vec![a_addr]).await;
    let (c, _c, c_addr) = start(&p[2], &with_c, vec![]).await; // c dials nobody: only a's dialer can reach it
    let (cid, aid) = (c.member_id(), a.member_id());
    a.add_peer_addr(c_addr.clone());
    b.add_peer_addr(c_addr);

    let up = |rx: &mut broadcast::Receiver<NodeEvent>, who: MemberId| {
        while let Ok(e) = rx.try_recv() {
            if matches!(e, NodeEvent::PeerUp { member, .. } if member == who) {
                return Some(());
            }
        }
        None
    };
    wait_for(Duration::from_secs(10), "a and b to meet", || up(&mut b_events, aid)).await;
    assert_eq!(member_ids(&a).len(), 2, "c is not known to a yet");

    assert!(a.admit(new_member(&p[2], "c")).unwrap());
    wait_for(Duration::from_secs(15), "a to connect to c", || up(&mut a_events, cid)).await;
    // b hears of c through a's StateSync, then dials c as well.
    wait_for(Duration::from_secs(15), "b to learn of c", || (member_ids(&b).len() == 3).then_some(())).await;
    wait_for(Duration::from_secs(15), "b to connect to c", || up(&mut b_events, cid)).await;

    // The admission was saved by both a and b.
    for q in [&p[0], &p[1]] {
        assert_eq!(CommunityState::load(&file(q)).unwrap().members.len(), 3);
    }
    assert!(!a.admit(new_member(&p[2], "c")).unwrap(), "already a member");
}

#[tokio::test]
async fn three_nodes_converge_after_concurrent_admissions() {
    let p = peers(6);
    let base = CommunityState::for_tests("live", &[(&p[0].id, "a", true), (&p[1].id, "b", true), (&p[2].id, "c", true)]);
    let (a, _, a_addr) = start(&p[0], &base, vec![]).await;
    let (b, _, b_addr) = start(&p[1], &base, vec![a_addr.clone()]).await;
    let (c, _, _) = start(&p[2], &base, vec![a_addr, b_addr]).await;
    wait_for(Duration::from_secs(15), "the three to connect", || {
        (a.host_state().host.is_some() && b.host_state().host.is_some() && c.host_state().host.is_some()).then_some(())
    })
    .await;

    // Each admits a different new member at the same moment.
    let (ra, rb, rc) = tokio::join!(
        async { a.admit(new_member(&p[3], "d")) },
        async { b.admit(new_member(&p[4], "e")) },
        async { c.admit(new_member(&p[5], "f")) },
    );
    assert!(ra.unwrap() && rb.unwrap() && rc.unwrap());

    let want: Vec<MemberId> = {
        let mut v: Vec<MemberId> = p.iter().map(|q| q.id.member_id()).collect();
        v.sort();
        v
    };
    for n in [&a, &b, &c] {
        wait_for(Duration::from_secs(15), "all six members everywhere", || (member_ids(n) == want).then_some(())).await;
    }
    // `load` verifies every entry against the chain of admitters.
    for q in &p[..3] {
        let s = CommunityState::load(&file(q)).unwrap();
        assert_eq!(s.members.keys().copied().collect::<Vec<_>>().len(), 6);
        assert!(s.members.values().all(|e| s.verify_entry(e)));
    }
}

#[tokio::test]
async fn members_changed_fires_once_per_real_change() {
    let p = peers(4);
    let base = CommunityState::for_tests("live", &[(&p[0].id, "a", true), (&p[1].id, "b", true)]);
    let (a, mut a_events, a_addr) = start(&p[0], &base, vec![]).await;
    let (b, mut b_events, _) = start(&p[1], &base, vec![a_addr]).await;
    wait_for(Duration::from_secs(10), "a and b to connect", || {
        (a.host_state().host.is_some() && b.host_state().host.is_some()).then_some(())
    })
    .await;
    // Hello and the first StateSync changed nothing.
    assert_eq!(changes(&mut a_events) + changes(&mut b_events), 0);

    assert!(a.admit(new_member(&p[2], "c")).unwrap());
    wait_for(Duration::from_secs(10), "b to learn of c", || (member_ids(&b).len() == 3).then_some(())).await;
    // Give the echo (b's own broadcast back to a) time to arrive; it must change nothing.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(changes(&mut a_events), 1, "a");
    assert_eq!(changes(&mut b_events), 1, "b");

    // Nothing new: no event.
    assert!(!a.admit(new_member(&p[2], "c")).unwrap());
    // Another real change fires again, once.
    assert!(b.admit(new_member(&p[3], "d")).unwrap());
    wait_for(Duration::from_secs(10), "a to learn of d", || (member_ids(&a).len() == 4).then_some(())).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(changes(&mut a_events), 1, "a");
    assert_eq!(changes(&mut b_events), 1, "b");
}
