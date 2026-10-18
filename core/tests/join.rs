//! The join door and protocol between in-process hubs: relays disabled, FakeHost media, and
//! every hub taught every other's main and door address (the address book stands in for relays).
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use hubbub_core::community::CommunityState;
use hubbub_core::hub::{Hub, HubConfig};
use hubbub_core::identity::Identity;
use hubbub_core::ids::{CommunityId, MemberId};
use hubbub_core::invite::{Deny, Invite};
use hubbub_core::join::{JoinEvent, JoinMsg, JoinTiming};
use hubbub_core::media_host::{FakeHost, MediaHost};
use hubbub_core::net::RelayChoice;
use hubbub_core::node::NodeEvent;
use hubbub_core::proto::{read_json, write_json, JOIN_ALPN};
use tokio::sync::mpsc;

fn fake(_: &Path) -> Box<dyn MediaHost> {
    Box::new(FakeHost::new())
}

fn fast() -> JoinTiming {
    JoinTiming {
        stagger: [Duration::ZERO, Duration::from_millis(50), Duration::from_millis(100)],
        attempt_timeout: Duration::from_secs(3),
        cycle: Duration::from_millis(300),
    }
}

async fn open(root: &Path) -> Hub {
    let cfg = HubConfig { can_host: true, relay: RelayChoice::Disabled, livekit_bin: None };
    let hub = Hub::open_with_test_media(root, cfg, fake).await.unwrap();
    hub.set_join_timing(fast());
    hub
}

/// Teaches each hub where the other's endpoint and door are.
fn introduce(hubs: &[&Hub]) {
    for x in hubs {
        for y in hubs {
            x.add_peer_addr(y.endpoint_addr());
            x.add_peer_addr(y.door_addr());
        }
    }
}

async fn wait_for<T>(within: Duration, what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let start = Instant::now();
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(start.elapsed() < within, "timed out after {within:?} waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn state_file(root: &Path, cid: &CommunityId) -> std::path::PathBuf {
    root.join("communities").join(cid.to_string()).join("community.json")
}

/// A link by the hub in `root`, which must be a member of `cid`.
fn invite(root: &Path, cid: &CommunityId, minutes: u32, uses: u8, extra: &[MemberId]) -> Invite {
    let id = Identity::load_or_create(root).unwrap();
    let state = CommunityState::load(&state_file(root, cid)).unwrap();
    Invite::create(&id, &state, minutes, uses, extra)
}

async fn join(hub: &Hub, link: &str) -> (anyhow::Result<CommunityId>, Vec<JoinEvent>) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let result = hub.join(link, tx).await;
    let mut events = Vec::new();
    while let Ok(e) = rx.try_recv() {
        events.push(e);
    }
    (result, events)
}

fn bodies(hub: &Hub, cid: &CommunityId) -> Vec<String> {
    hub.node(cid).unwrap().text_history("general", 50).unwrap().into_iter().map(|m| m.body).collect()
}

async fn expect_text(hub: &Hub, cid: &CommunityId, want: &str) {
    wait_for(Duration::from_secs(30), want, || bodies(hub, cid).contains(&want.to_string()).then_some(())).await;
}

fn denied(r: (anyhow::Result<CommunityId>, Vec<JoinEvent>), want: Deny) {
    let (result, events) = r;
    assert_eq!(result.unwrap_err().downcast_ref::<Deny>(), Some(&want));
    assert_eq!(events.last(), Some(&JoinEvent::Denied(want)), "{events:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_accepted_join_starts_the_server_and_the_new_member_texts_the_others() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(da.path()).await, open(db.path()).await);
    introduce(&[&a, &b]);
    let cid = a.create_community("Friends").await.unwrap();
    let link = invite(da.path(), &cid, 60, 0, &[]).to_link();

    let (result, events) = join(&b, &link).await;
    assert_eq!(result.unwrap(), cid);
    assert_eq!(events.first(), Some(&JoinEvent::Trying));
    assert_eq!(events.last(), Some(&JoinEvent::Joined(cid)));
    assert_eq!(b.communities(), vec![(cid, "Friends".to_string())]);
    let members = b.node(&cid).unwrap().members();
    assert!(members.iter().any(|(m, _)| *m == b.member_id()));
    assert!(members.iter().any(|(m, _)| *m == a.member_id()));

    b.node(&cid).unwrap().send_text("general", "hello from b").await.unwrap();
    expect_text(&a, &cid, "hello from b").await;
    a.node(&cid).unwrap().send_text("general", "hello from a").await.unwrap();
    expect_text(&b, &cid, "hello from a").await;
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_revoked_used_up_and_unknown_inviter_are_each_denied() {
    let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    // A's server is built by hand so one invite is revoked from the start.
    let id_a = Identity::load_or_create(dirs[0].path()).unwrap();
    let mut state = CommunityState::create_as("Friends", &id_a, "A", true);
    let cid = state.id;
    let revoked = Invite::create(&id_a, &state, 60, 0, &[]);
    state.revoke(revoked.invite_id);
    std::fs::create_dir_all(state_file(dirs[0].path(), &cid).parent().unwrap()).unwrap();
    state.save_atomic(&state_file(dirs[0].path(), &cid)).unwrap();
    let (a, b, c) = (open(dirs[0].path()).await, open(dirs[1].path()).await, open(dirs[2].path()).await);
    introduce(&[&a, &b, &c]);

    denied(join(&b, &revoked.to_link()).await, Deny::Revoked);
    let expired = Invite::create_at(&id_a, &state, 10, 0, &[], 1000);
    denied(join(&b, &expired.to_link()).await, Deny::Expired);
    // Signed by someone who is not a member; A's door is its second.
    let stranger = Identity::from_secret_bytes([9; 32]);
    let forged = Invite::create(&stranger, &state, 60, 0, &[id_a.door_id()]);
    denied(join(&b, &forged.to_link()).await, Deny::UnknownInviter);
    assert!(b.communities().is_empty(), "a denied join leaves nothing behind");

    let once = invite(dirs[0].path(), &cid, 60, 1, &[]).to_link();
    join(&b, &once).await.0.unwrap();
    denied(join(&c, &once).await, Deny::UsedUp);
    assert!(c.communities().is_empty());
    for h in [&a, &b, &c] {
        h.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_existing_member_who_asks_again_is_accepted_and_uses_nothing_up() {
    let (da, db, dc) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b, c) = (open(da.path()).await, open(db.path()).await, open(dc.path()).await);
    introduce(&[&a, &b, &c]);
    let cid = a.create_community("Friends").await.unwrap();
    let once = invite(da.path(), &cid, 60, 1, &[]).to_link();
    join(&b, &once).await.0.unwrap();
    // B drops the server from its device and uses the used-up link again: still let in.
    b.leave(&cid).await.unwrap();
    assert_eq!(join(&b, &once).await.0.unwrap(), cid);
    assert_eq!(a.node(&cid).unwrap().members().len(), 2);
    denied(join(&c, &once).await, Deny::UsedUp);
    for h in [&a, &b, &c] {
        h.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_every_door_offline_the_joiner_waits_and_completes_when_one_comes_online() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = open(da.path()).await;
    let cid = a.create_community("Friends").await.unwrap();
    let link = invite(da.path(), &cid, 60, 0, &[]).to_link();
    a.shutdown().await;
    drop(a);

    let b = Arc::new(open(db.path()).await);
    let (tx, mut rx) = mpsc::unbounded_channel();
    let task = {
        let (b, link) = (b.clone(), link.clone());
        tokio::spawn(async move { b.join(&link, tx).await })
    };
    assert_eq!(rx.recv().await, Some(JoinEvent::Trying));
    assert_eq!(rx.recv().await, Some(JoinEvent::Offline));
    assert!(!task.is_finished());

    let a = open(da.path()).await;
    introduce(&[&a, &b]);
    assert_eq!(task.await.unwrap().unwrap(), cid);
    assert_eq!(b.communities().len(), 1);
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancelled_join_leaves_nothing_behind() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = open(da.path()).await;
    let cid = a.create_community("Friends").await.unwrap();
    let link = invite(da.path(), &cid, 60, 0, &[]).to_link();
    a.shutdown().await;
    let b = open(db.path()).await;
    let (tx, mut rx) = mpsc::unbounded_channel();
    let attempt = tokio::time::timeout(Duration::from_millis(800), b.join(&link, tx)).await;
    assert!(attempt.is_err(), "nobody is online, so the join is still waiting");
    assert_eq!(rx.recv().await, Some(JoinEvent::Trying));
    assert!(b.communities().is_empty());
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_member_admitted_while_another_was_offline_reaches_it_with_rejoin() {
    let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let (a, b, c) = (open(dirs[0].path()).await, open(dirs[1].path()).await, open(dirs[2].path()).await);
    introduce(&[&a, &b, &c]);
    let cid = a.create_community("Friends").await.unwrap();
    let link = invite(dirs[0].path(), &cid, 60, 0, &[]).to_link();
    join(&c, &link).await.0.unwrap(); // Carol, while Alice is the only other member
    c.shutdown().await;
    drop(c);
    join(&b, &link).await.0.unwrap(); // Bob, admitted while Carol is offline
    a.shutdown().await; // and Alice goes, so only Bob and Carol are left
    drop(a);

    let c = open(dirs[2].path()).await;
    c.add_peer_addr(b.endpoint_addr());
    b.add_peer_addr(c.endpoint_addr());
    let carol = c.node(&cid).unwrap();
    let (mut b_events, mut c_events) = (b.node(&cid).unwrap().subscribe(), carol.subscribe());
    assert!(!carol.members().iter().any(|(m, _)| *m == b.member_id()), "Carol has not heard of Bob");

    wait_for(Duration::from_secs(30), "Carol learns Bob", || {
        carol.members().iter().any(|(m, _)| *m == b.member_id()).then_some(())
    })
    .await;
    // And they hold a control session with each other, though no third member is online.
    let seen = |rx: &mut tokio::sync::broadcast::Receiver<NodeEvent>, who: MemberId| {
        std::iter::from_fn(|| rx.try_recv().ok()).any(|e| matches!(e, NodeEvent::PeerUp { member, .. } if member == who))
    };
    let (mut b_sees_c, mut c_sees_b) = (false, false);
    wait_for(Duration::from_secs(30), "a session between Bob and Carol", || {
        b_sees_c |= seen(&mut b_events, c.member_id());
        c_sees_b |= seen(&mut c_events, b.member_id());
        (b_sees_c && c_sees_b).then_some(())
    })
    .await;
    c.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_members_admitting_the_same_joiner_converge() {
    let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let (a, b, d) = (open(dirs[0].path()).await, open(dirs[1].path()).await, open(dirs[2].path()).await);
    introduce(&[&a, &b, &d]);
    let cid = a.create_community("Friends").await.unwrap();
    let id_b = Identity::load_or_create(dirs[1].path()).unwrap();
    // B joins; then each of the two admits D at once, from its own door.
    let link = invite(dirs[0].path(), &cid, 60, 0, &[id_b.door_id()]).to_link();
    join(&b, &link).await.0.unwrap();
    let id_d = Identity::load_or_create(dirs[2].path()).unwrap();
    let ask = |door: iroh::EndpointAddr| {
        let (d, link, door_id) = (&d, link.clone(), id_d.door_id());
        async move {
            let conn = d.switch().connect_raw(door, JOIN_ALPN).await.unwrap();
            let (mut send, mut recv) = conn.open_bi().await.unwrap();
            let req = JoinMsg::JoinRequest { cid, invite: link, name: "D".into(), can_host: true, door: door_id };
            write_json(&mut send, &req).await.unwrap();
            let reply: Option<JoinMsg> = read_json(&mut recv).await.unwrap();
            assert!(matches!(reply, Some(JoinMsg::JoinAccepted { .. })), "{reply:?}");
        }
    };
    tokio::join!(ask(a.door_addr()), ask(b.door_addr()));

    let members = |root: &Path| CommunityState::load(&state_file(root, &cid)).unwrap().members;
    wait_for(Duration::from_secs(30), "A and B hold the same members", || {
        let (ma, mb) = (members(dirs[0].path()), members(dirs[1].path()));
        (ma.contains_key(&d.member_id()) && ma == mb).then_some(())
    })
    .await;
    assert_eq!(members(dirs[0].path()).len(), 3);
    for h in [&a, &b, &d] {
        h.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_door_refuses_the_eleventh_request_inside_a_minute() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(da.path()).await, open(db.path()).await);
    introduce(&[&a, &b]);
    let cid = a.create_community("Friends").await.unwrap();
    let id_b = Identity::load_or_create(db.path()).unwrap();
    let ask = || async {
        let conn = b.switch().connect_raw(a.door_addr(), JOIN_ALPN).await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        let req = JoinMsg::JoinRequest { cid, invite: "junk".into(), name: "B".into(), can_host: true, door: id_b.door_id() };
        write_json(&mut send, &req).await?;
        read_json::<JoinMsg>(&mut recv).await
    };
    for n in 1..=10 {
        let reply = ask().await.unwrap_or_else(|e| panic!("request {n}: {e:#}"));
        assert!(matches!(reply, Some(JoinMsg::JoinDenied { .. })), "request {n}: {reply:?}");
    }
    assert!(ask().await.map(|r| r.is_none()).unwrap_or(true), "the 11th is turned away");
    a.shutdown().await;
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hub_that_has_shut_down_answers_no_join() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(da.path()).await, open(db.path()).await);
    introduce(&[&a, &b]);
    let addr = a.door_addr();
    a.shutdown().await;
    let dialed = tokio::time::timeout(Duration::from_secs(5), b.switch().connect_raw(addr, JOIN_ALPN)).await;
    assert!(!matches!(dialed, Ok(Ok(_))), "the door is closed");
    b.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_same_link_joined_twice_at_once_starts_one_node_and_shutdown_stops_it() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(da.path()).await, open(db.path()).await);
    introduce(&[&a, &b]);
    let cid = a.create_community("Friends").await.unwrap();
    let link = invite(da.path(), &cid, 60, 0, &[]).to_link();
    let (r1, r2) = tokio::join!(join(&b, &link), join(&b, &link));
    let (oks, errs): (Vec<_>, Vec<_>) = [r1.0, r2.0].into_iter().partition(|r| r.is_ok());
    assert_eq!((oks.len(), errs.len()), (1, 1), "one join wins, the other is told it is already joining");
    assert!(errs[0].as_ref().unwrap_err().to_string().contains("already joining"));
    assert_eq!(b.communities().len(), 1);
    // The guard is released: joining again is the "already a member" no-op.
    assert_eq!(join(&b, &link).await.0.unwrap(), cid);

    // Shutdown stops the node: its route is gone, so the hub's endpoint serves no ALPN of it.
    let node = b.node(&cid).unwrap();
    b.shutdown().await;
    assert!(b.switch().alpns().is_empty(), "no server left on the endpoint");
    drop(node);
    a.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_makes_and_revokes_its_own_invites() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (open(da.path()).await, open(db.path()).await);
    introduce(&[&a, &b]);
    let cid = a.create_community("Friends").await.unwrap();
    let node = a.node(&cid).unwrap();
    assert!(node.is_owner());
    assert_eq!(node.community_name(), "Friends");

    let link = node.invite_create(60, 0);
    assert_eq!(Invite::parse(&link).unwrap().cid, cid);
    node.invite_revoke(&link).unwrap();
    denied(join(&b, &link).await, Deny::Revoked);

    let fresh = node.invite_create(0, 0);
    assert_eq!(join(&b, &fresh).await.0.unwrap(), cid);
    assert!(!b.node(&cid).unwrap().is_owner());
    a.shutdown().await;
    b.shutdown().await;
}
