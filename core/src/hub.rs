//! The hub: one per device. It owns the identity and the single iroh endpoint, and runs one
//! `Node` per server the device is in. Each server has its own ALPN pair on the shared
//! endpoint, so a connection reaches only the server it names, and only its members.
//!
//! Layout under the root folder:
//! - `identity.key`, `profile.json` (`{ "name": … }`) and `hub.lock`;
//! - `communities/<cid-hex>/`: `community.json` and the text store;
//! - `livekit/`: the work dir of the machine's one LiveKit, shared by every server;
//! - `archive/<cid-hex>-<unix-secs>/`: servers this device left.
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::community::{clamp_name, CommunityState};
use crate::invite::Invite;
use crate::join::{self, Door, JoinEvent, JoinTiming};
use crate::identity::Identity;
use crate::ids::{CommunityId, MemberId};
use crate::media_host::{LiveKitHost, LkPorts, MediaHost, NoMediaHost};
use crate::media_shared::SharedMedia;
use crate::net::{RelayChoice, Switch};
use crate::node::{uses_upnp, Node, NodeConfig};

pub struct HubConfig {
    /// Whether this device may host media for its servers.
    pub can_host: bool,
    pub relay: RelayChoice,
    /// The `livekit-server` binary; without it the device never hosts.
    pub livekit_bin: Option<PathBuf>,
}

#[derive(Serialize, Deserialize)]
struct Profile {
    name: String,
}

struct Server {
    name: String,
    node: Arc<Node>,
}

pub struct Hub {
    root: PathBuf,
    cfg: HubConfig,
    identity: Arc<Identity>,
    profile: Mutex<Profile>,
    switch: Arc<Switch>,
    /// The machine's one media host and UPnP mapping, leased by each hosting server.
    media: Arc<SharedMedia>,
    servers: Arc<Mutex<BTreeMap<CommunityId, Server>>>,
    /// The join door: a second, relay-only endpoint that strangers with a link may dial.
    door: Door,
    join_timing: Mutex<JoinTiming>,
    /// Servers a `join` is working on, so one link joined twice at once starts one node.
    joining: Mutex<HashSet<CommunityId>>,
    /// Held for the hub's life; the OS releases the lock when this is dropped.
    _lock: File,
}

impl Hub {
    /// Opens the hub in `root` (created if absent) and starts a node for every server in it.
    /// Fails if another process already has `root` open.
    pub async fn open(root: &Path, cfg: HubConfig) -> Result<Hub> {
        let bin = cfg.livekit_bin.clone();
        let can_host = cfg.can_host;
        let make = move |root: &Path| -> Box<dyn MediaHost> {
            match (&bin, can_host) {
                (Some(bin), true) => Box::new(LiveKitHost::new(bin.clone(), root.join("livekit"), LkPorts::default())),
                _ => Box::new(NoMediaHost),
            }
        };
        Self::open_with_media(root, cfg, make).await
    }

    /// `open` with the machine's media host supplied by `media` (tests use `FakeHost`).
    #[cfg(feature = "test-util")]
    pub async fn open_with_test_media(
        root: &Path,
        cfg: HubConfig,
        media: impl FnOnce(&Path) -> Box<dyn MediaHost>,
    ) -> Result<Hub> {
        Self::open_with_media(root, cfg, media).await
    }

    async fn open_with_media(
        root: &Path,
        cfg: HubConfig,
        media: impl FnOnce(&Path) -> Box<dyn MediaHost>,
    ) -> Result<Hub> {
        fs::create_dir_all(root).with_context(|| format!("creating {}", root.display()))?;
        let lock_path = root.join("hub.lock");
        let lock = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("opening {}", lock_path.display()))?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                bail!("another Hubbub is using {}; close it first", root.display())
            }
            Err(TryLockError::Error(e)) => {
                return Err(e).with_context(|| format!("locking {}", lock_path.display()))
            }
        }
        let identity = Arc::new(Identity::load_or_create(root)?);
        let profile = load_profile(root, &identity)?;
        let switch = Arc::new(Switch::bind(&identity, cfg.relay).await?);
        // One LiveKit per machine, working in `<root>/livekit/`.
        let upnp = uses_upnp(cfg.can_host, cfg.relay);
        let media = Arc::new(SharedMedia::new(media(root), upnp, LkPorts::default().rtc_udp));
        let servers: Arc<Mutex<BTreeMap<CommunityId, Server>>> = Arc::default();
        let by_cid = servers.clone();
        let nodes: join::NodeLookup = Arc::new(move |cid| by_cid.lock().unwrap().get(cid).map(|s| s.node.clone()));
        let door = Door::start(&identity, cfg.relay, nodes).await?;
        let hub = Hub {
            root: root.to_path_buf(),
            cfg,
            identity,
            profile: Mutex::new(profile),
            switch,
            media,
            servers,
            door,
            join_timing: Mutex::new(JoinTiming::default()),
            joining: Mutex::default(),
            _lock: lock,
        };
        let dir = hub.communities_dir();
        if dir.is_dir() {
            for entry in fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))? {
                let path = entry?.path();
                let file = path.join("community.json");
                if file.is_file() {
                    hub.start_server(&path).await.with_context(|| format!("starting {}", path.display()))?;
                }
            }
        }
        Ok(hub)
    }

    pub fn member_id(&self) -> MemberId {
        self.identity.member_id()
    }

    pub fn profile_name(&self) -> String {
        self.profile.lock().unwrap().name.clone()
    }

    /// Sets the name this device gives itself in servers it creates or joins later.
    pub fn set_profile_name(&self, name: &str) -> Result<()> {
        let profile = Profile { name: clamp_name(name) };
        write_json(&self.root.join("profile.json"), &profile)?;
        *self.profile.lock().unwrap() = profile;
        Ok(())
    }

    /// Makes a new server owned by this device and starts its node.
    pub async fn create_community(&self, name: &str) -> Result<CommunityId> {
        let state =
            CommunityState::create_as(name, &self.identity, &self.profile_name(), self.cfg.can_host);
        let dir = self.communities_dir().join(state.id.to_string());
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        state.save_atomic(&dir.join("community.json"))?;
        self.start_server(&dir).await?;
        Ok(state.id)
    }

    /// Joins the server `link` invites to, through the door of whichever member is online, and
    /// starts its node: afterwards `communities()` lists it and `node(cid)` runs it, as for
    /// `create_community`. `events` reports progress: `Trying`, `Offline` while no door answers
    /// (the dialing then repeats), and a final `Denied(reason)` (also returned as an error,
    /// which downcasts to `Deny`) or `Joined(cid)`. A join that is already a member returns
    /// at once. Dropping the returned future cancels the join.
    pub async fn join(&self, link: &str, events: mpsc::UnboundedSender<JoinEvent>) -> Result<CommunityId> {
        let invite = Invite::parse(link)?;
        if self.servers.lock().unwrap().contains_key(&invite.cid) {
            let _ = events.send(JoinEvent::Joined(invite.cid));
            return Ok(invite.cid);
        }
        let _joining = JoinGuard::new(&self.joining, invite.cid)?;
        let timing = *self.join_timing.lock().unwrap();
        let answer = join::request(
            &self.switch,
            &self.identity,
            &invite,
            link,
            &self.profile_name(),
            self.cfg.can_host,
            timing,
            &events,
        )
        .await?;
        let state = match answer {
            Ok(state) => state,
            Err(reason) => {
                let _ = events.send(JoinEvent::Denied(reason));
                return Err(reason.into());
            }
        };
        let dir = self.communities_dir().join(state.id.to_string());
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        state.save_atomic(&dir.join("community.json"))?;
        // A device invited again after it was removed starts its text history now.
        crate::text::mark_joined(&dir);
        self.start_server(&dir).await?;
        let _ = events.send(JoinEvent::Joined(state.id));
        Ok(state.id)
    }

    /// Every server this device is in, with its name.
    pub fn communities(&self) -> Vec<(CommunityId, String)> {
        self.servers.lock().unwrap().iter().map(|(id, s)| (*id, s.name.clone())).collect()
    }

    pub fn node(&self, cid: &CommunityId) -> Option<Arc<Node>> {
        self.servers.lock().unwrap().get(cid).map(|s| s.node.clone())
    }

    /// Leaves a server on this device only: stops its node, stops answering its ALPNs, and
    /// moves its folder to `archive/<cid-hex>-<unix-secs>/`.
    pub async fn leave(&self, cid: &CommunityId) -> Result<()> {
        let server = self.servers.lock().unwrap().remove(cid).with_context(|| format!("not in server {cid}"))?;
        server.node.shutdown_ref().await;
        drop(server);
        let from = self.communities_dir().join(cid.to_string());
        let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let archive = self.root.join("archive");
        fs::create_dir_all(&archive).with_context(|| format!("creating {}", archive.display()))?;
        let to = archive.join(format!("{cid}-{secs}"));
        // Windows keeps a folder busy for a moment after its last file closes.
        let mut tries = 0;
        loop {
            match fs::rename(&from, &to) {
                Ok(()) => return Ok(()),
                Err(e) if tries >= 20 => {
                    return Err(e).with_context(|| format!("archiving {}", from.display()))
                }
                Err(_) => {
                    tries += 1;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    }

    /// Leaves every server gracefully, then closes the endpoint.
    pub async fn shutdown(&self) {
        // The door first, so no join is answered while the servers go.
        self.door.close().await;
        let servers = std::mem::take(&mut *self.servers.lock().unwrap());
        for server in servers.into_values() {
            server.node.shutdown_ref().await;
        }
        self.switch.close().await;
    }

    /// The shared endpoint, for tests.
    #[cfg(feature = "test-util")]
    pub fn switch(&self) -> &Arc<Switch> {
        &self.switch
    }

    /// Where to dial this hub's endpoint in a same-machine test.
    #[cfg(feature = "test-util")]
    pub fn endpoint_addr(&self) -> iroh::EndpointAddr {
        self.switch.addr()
    }

    /// Where to dial this hub's join door in a same-machine test; teach it to the joiner's hub
    /// with `add_peer_addr`.
    #[cfg(feature = "test-util")]
    pub fn door_addr(&self) -> iroh::EndpointAddr {
        self.door.addr()
    }

    /// Shortens the joiner's stagger, attempt time-out and retry cycle (tests).
    #[cfg(feature = "test-util")]
    pub fn set_join_timing(&self, timing: JoinTiming) {
        *self.join_timing.lock().unwrap() = timing;
    }

    /// Teaches this hub's endpoint where a peer is (tests have no address lookup service).
    #[cfg(feature = "test-util")]
    pub fn add_peer_addr(&self, addr: iroh::EndpointAddr) {
        self.switch.add_peer_addr(addr);
    }

    fn communities_dir(&self) -> PathBuf {
        self.root.join("communities")
    }

    /// Starts the node of the server saved in `dir`. Refuses a server that is already running.
    async fn start_server(&self, dir: &Path) -> Result<()> {
        let file = dir.join("community.json");
        let state = CommunityState::load(&file)?;
        ensure!(!self.servers.lock().unwrap().contains_key(&state.id), "server {} is already running", state.id);
        let cfg = NodeConfig {
            data_dir: dir.to_path_buf(),
            community_file: file,
            can_host: self.cfg.can_host,
            relay: self.cfg.relay,
        };
        let node = Node::start_in_hub(cfg, self.media.clone(), self.switch.clone(), self.identity.clone()).await?;
        {
            let mut servers = self.servers.lock().unwrap();
            if !servers.contains_key(&state.id) {
                servers.insert(state.id, Server { name: state.name.clone(), node: Arc::new(node) });
                return Ok(());
            }
        }
        // Another start won while this node was coming up: stop ours rather than leave it running.
        node.shutdown().await;
        bail!("server {} is already running", state.id)
    }
}

/// Marks a server as being joined until dropped (also when the join is cancelled).
struct JoinGuard<'a> {
    set: &'a Mutex<HashSet<CommunityId>>,
    cid: CommunityId,
}

impl<'a> JoinGuard<'a> {
    fn new(set: &'a Mutex<HashSet<CommunityId>>, cid: CommunityId) -> Result<Self> {
        ensure!(set.lock().unwrap().insert(cid), "already joining server {cid}");
        Ok(JoinGuard { set, cid })
    }
}

impl Drop for JoinGuard<'_> {
    fn drop(&mut self) {
        self.set.lock().unwrap().remove(&self.cid);
    }
}

fn load_profile(root: &Path, identity: &Identity) -> Result<Profile> {
    let path = root.join("profile.json");
    if path.exists() {
        let text = fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
        let mut p: Profile = serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
        p.name = clamp_name(&p.name);
        return Ok(p);
    }
    // No name chosen yet: the short member tag, as `CommunityState::create` does.
    let p = Profile { name: identity.member_id().tag() };
    write_json(&path, &p)?;
    Ok(p)
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(value)?).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))
}
