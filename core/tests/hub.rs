//! Hubs with in-process nodes: FakeHost media, relays disabled, peers found through each
//! hub's in-memory address book.
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use hubbub_core::community::NewMember;
use hubbub_core::hub::{Hub, HubConfig};
use hubbub_core::identity::Identity;
use hubbub_core::ids::{CommunityId, MemberId};
use hubbub_core::media_host::{FakeHost, MediaHost};
use hubbub_core::net::RelayChoice;
use hubbub_core::proto::{ctl_alpn, media_alpn, rejoin_alpn, sig_alpn};

fn cfg() -> HubConfig {
    HubConfig { can_host: true, relay: RelayChoice::Disabled, livekit_bin: None }
}

fn fake(_: &Path) -> Box<dyn MediaHost> {
    Box::new(FakeHost::new())
}

async fn open(root: &Path) -> Hub {
    Hub::open_with_test_media(root, cfg(), fake).await.unwrap()
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

/// Hub A owns servers `s1` and `s2`. Hub B is in both, hub C only in `s1`; all know each other's address.
struct Trio {
    dirs: Vec<tempfile::TempDir>,
    hubs: Vec<Hub>,
    s1: CommunityId,
    s2: CommunityId,
}

async fn trio() -> Trio {
    let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let ids: Vec<Identity> = dirs.iter().map(|d| Identity::load_or_create(d.path()).unwrap()).collect();
    let a = open(dirs[0].path()).await;
    let s1 = a.create_community("one").await.unwrap();
    let s2 = a.create_community("two").await.unwrap();
    // Admit B into both and C into s1, then hand each their saved state (no join flow yet).
    for (who, cid) in [(1, s1), (1, s2), (2, s1)] {
        let p = &ids[who];
        let m = NewMember { id: p.member_id(), name: format!("m{who}"), can_host: true, door: p.door_id(), via_invite: None };
        assert!(a.node(&cid).unwrap().admit(m).unwrap());
        let from = dirs[0].path().join("communities").join(cid.to_string()).join("community.json");
        let to_dir = dirs[who].path().join("communities").join(cid.to_string());
        std::fs::create_dir_all(&to_dir).unwrap();
        std::fs::copy(from, to_dir.join("community.json")).unwrap();
    }
    let (b, c) = (open(dirs[1].path()).await, open(dirs[2].path()).await);
    let hubs = vec![a, b, c];
    for x in &hubs {
        for y in &hubs {
            x.add_peer_addr(y.endpoint_addr());
        }
    }
    Trio { dirs, hubs, s1, s2 }
}

async fn text_bodies(hub: &Hub, cid: &CommunityId) -> Vec<String> {
    let bodies = hub.node(cid).unwrap().text_history("general", 50).unwrap();
    bodies.into_iter().map(|m| m.body).collect()
}

/// A dial with `alpn` is refused: it fails to connect, or is closed with 403 at once.
async fn assert_refused(from: &Hub, to: &Hub, alpn: &[u8]) {
    if let Ok(conn) = from.switch().connect_raw(to.endpoint_addr(), alpn).await {
        let err = tokio::time::timeout(Duration::from_secs(2), conn.closed())
            .await
            .expect("a refused connection is closed within 2 s");
        assert!(err.to_string().contains("403"), "unexpected close: {err}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_hubs_share_two_servers_and_each_servers_text_stays_separate() {
    let t = trio().await;
    let (a, b) = (&t.hubs[0], &t.hubs[1]);
    assert_eq!(a.communities().len(), 2);
    assert_eq!(b.communities().len(), 2);
    a.node(&t.s1).unwrap().send_text("general", "alpha").await.unwrap();
    b.node(&t.s2).unwrap().send_text("general", "beta").await.unwrap();
    let within = Duration::from_secs(30);
    for (hub, cid, want) in [(a, &t.s1, "alpha"), (b, &t.s1, "alpha"), (a, &t.s2, "beta"), (b, &t.s2, "beta")] {
        let mut got = Vec::new();
        wait_for(within, want, || {
            got = hub.node(cid).unwrap().text_history("general", 50).unwrap().into_iter().map(|m| m.body).collect();
            got.contains(&want.to_string()).then_some(())
        })
        .await;
    }
    for (hub, cid, want) in [(a, &t.s1, "alpha"), (b, &t.s1, "alpha"), (a, &t.s2, "beta"), (b, &t.s2, "beta")] {
        assert_eq!(text_bodies(hub, cid).await, vec![want.to_string()], "one server's text leaked into another");
    }
    // C is only in s1, so it sees alpha too and never beta.
    let c = &t.hubs[2];
    wait_for(within, "alpha at C", || text_bodies_sync(c, &t.s1).contains(&"alpha".to_string()).then_some(())).await;
    assert!(c.node(&t.s2).is_none());
    for h in &t.hubs {
        h.shutdown().await;
    }
    drop(t.dirs);
}

fn text_bodies_sync(hub: &Hub, cid: &CommunityId) -> Vec<String> {
    hub.node(cid).unwrap().text_history("general", 50).unwrap().into_iter().map(|m| m.body).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hub_in_only_one_server_refuses_the_others_alpn_both_ways() {
    let t = trio().await;
    let (a, c) = (&t.hubs[0], &t.hubs[2]);
    // C serves only s1's pair.
    assert_eq!(c.switch().alpns(), { let mut v = vec![ctl_alpn(&t.s1), sig_alpn(&t.s1), media_alpn(&t.s1), rejoin_alpn(&t.s1)]; v.sort(); v });
    // A dialing C for s2: C never offers that ALPN.
    assert!(a.switch().connect_raw(c.endpoint_addr(), &ctl_alpn(&t.s2)).await.is_err());
    assert!(a.switch().connect_raw(c.endpoint_addr(), &sig_alpn(&t.s2)).await.is_err());
    // C dialing A for s2: A offers it, but C is not a member there.
    assert_refused(c, a, &ctl_alpn(&t.s2)).await;
    assert_refused(c, a, &sig_alpn(&t.s2)).await;
    for h in &t.hubs {
        h.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn leaving_drops_the_servers_alpn_and_archives_it_but_not_the_other_server() {
    let t = trio().await;
    let (a, b) = (&t.hubs[0], &t.hubs[1]);
    assert!(b.switch().connect_raw(a.endpoint_addr(), &ctl_alpn(&t.s2)).await.is_ok());
    a.leave(&t.s2).await.unwrap();
    assert!(a.node(&t.s2).is_none());
    assert_eq!(a.communities().len(), 1);
    assert_eq!(a.switch().alpns(), { let mut v = vec![ctl_alpn(&t.s1), sig_alpn(&t.s1), media_alpn(&t.s1), rejoin_alpn(&t.s1)]; v.sort(); v });
    assert!(b.switch().connect_raw(a.endpoint_addr(), &ctl_alpn(&t.s2)).await.is_err());
    assert!(b.switch().connect_raw(a.endpoint_addr(), &sig_alpn(&t.s2)).await.is_err());
    let live = dirs_of(t.dirs[0].path().join("communities"));
    assert_eq!(live, vec![t.s1.to_string()]);
    let archived = dirs_of(t.dirs[0].path().join("archive"));
    assert_eq!(archived.len(), 1);
    assert!(archived[0].starts_with(&format!("{}-", t.s2)), "{archived:?}");
    assert!(a.leave(&t.s2).await.is_err(), "leaving twice is an error");
    // The other server is untouched and still delivers.
    a.node(&t.s1).unwrap().send_text("general", "still here").await.unwrap();
    wait_for(Duration::from_secs(30), "text in s1 at B", || {
        text_bodies_sync(b, &t.s1).contains(&"still here".to_string()).then_some(())
    })
    .await;
    for h in &t.hubs {
        h.shutdown().await;
    }
}

fn dirs_of(p: std::path::PathBuf) -> Vec<String> {
    let mut v: Vec<String> =
        std::fs::read_dir(p).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

#[tokio::test]
async fn a_second_hub_on_the_same_root_fails_until_the_first_is_gone() {
    let d = tempfile::tempdir().unwrap();
    let first = open(d.path()).await;
    let err = match Hub::open_with_test_media(d.path(), cfg(), fake).await {
        Ok(_) => panic!("a second hub opened on a locked root"),
        Err(e) => format!("{e:#}"),
    };
    assert!(err.contains("another Hubbub") && err.contains(&d.path().display().to_string()), "{err}");
    first.shutdown().await;
    drop(first);
    open(d.path()).await.shutdown().await;
}

#[tokio::test]
async fn servers_and_the_profile_name_survive_a_restart() {
    let d = tempfile::tempdir().unwrap();
    let (me, cid) = {
        let hub = open(d.path()).await;
        assert_eq!(hub.profile_name(), hub.member_id().tag());
        hub.set_profile_name("Shawn").unwrap();
        let cid = hub.create_community("Shawn's server").await.unwrap();
        hub.shutdown().await;
        (hub.member_id(), cid)
    };
    let hub = open(d.path()).await;
    assert_eq!(hub.member_id(), me);
    assert_eq!(hub.profile_name(), "Shawn");
    assert_eq!(hub.communities(), vec![(cid, "Shawn's server".to_string())]);
    let members = hub.node(&cid).unwrap().members();
    assert_eq!(members, vec![(me, "Shawn".to_string())], "the owner is named by the profile");
    hub.shutdown().await;
}

/// A FakeHost that counts its starts.
struct CountingHost {
    inner: FakeHost,
    starts: Arc<AtomicUsize>,
}

#[async_trait::async_trait]
impl MediaHost for CountingHost {
    async fn start(&mut self, ip: IpAddr) -> anyhow::Result<SocketAddr> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        self.inner.start(ip).await
    }
    async fn stop(&mut self) {
        self.inner.stop().await
    }
    fn mint(&self, member: &MemberId, name: &str, room: &str) -> anyhow::Result<String> {
        self.inner.mint(member, name, room)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_hosting_servers_share_one_media_host_and_name_their_rooms_apart() {
    let dir = tempfile::tempdir().unwrap();
    let starts = Arc::new(AtomicUsize::new(0));
    let counter = starts.clone();
    let media = move |_: &Path| -> Box<dyn MediaHost> { Box::new(CountingHost { inner: FakeHost::new(), starts: counter }) };
    let hub = Hub::open_with_test_media(dir.path(), cfg(), media).await.unwrap();
    let (s1, s2) = (hub.create_community("one").await.unwrap(), hub.create_community("two").await.unwrap());
    let me = hub.member_id();
    // Each server is just this device, so each elects it as host.
    let mut tokens = Vec::new();
    for cid in [s1, s2] {
        let c = hub.node(&cid).unwrap().voice_credentials("lobby").await.unwrap();
        assert_eq!(c.token, format!("fake:{me}:{cid}.lobby"));
        tokens.push(c.token);
    }
    assert_ne!(tokens[0], tokens[1]);
    assert_eq!(starts.load(Ordering::SeqCst), 1, "one media host for both servers");
    hub.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_host_denies_a_token_for_a_channel_that_is_not_a_voice_channel() {
    let dir = tempfile::tempdir().unwrap();
    let hub = open(dir.path()).await;
    let cid = hub.create_community("one").await.unwrap();
    let node = hub.node(&cid).unwrap();
    // The host is up and mints for the real voice channel, so a denial below is the channel check.
    node.voice_credentials("lobby").await.unwrap();
    // "general" exists, as a text channel.
    let err = node.voice_credentials("general").await.err().expect("a text channel must be denied");
    assert!(format!("{err:#}").contains("is not a voice channel"), "unexpected error: {err:#}");
    hub.shutdown().await;
}
