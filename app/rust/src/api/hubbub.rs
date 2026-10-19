//! Flutter-facing API over `hubbub-core`. Node work runs on a dedicated
//! multi-thread tokio runtime because iroh needs one.
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;
use hubbub_core::media_host::{LiveKitHost, LkPorts, MediaHost, NoMediaHost};
use hubbub_core::hub::{Hub, HubConfig};
use hubbub_core::ids::CommunityId;
use hubbub_core::invite::{Deny, Invite};
use hubbub_core::join::JoinEvent;
use hubbub_core::proto::VoicePresence;
use hubbub_core::net::{ConnKind, RelayChoice};
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use sysinfo::{get_current_pid, ProcessRefreshKind, ProcessesToUpdate, System};
use hubbub_core::election::HostState;
use hubbub_core::ids::MemberId;
use hubbub_core::text::TextMessage;
use tokio::sync::broadcast::{self, error::RecvError};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use crate::frb_generated::StreamSink;

pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Runs `fut` on the node runtime and awaits it from whatever executor FRB uses.
async fn on_runtime<T: Send + 'static>(
    fut: impl std::future::Future<Output = anyhow::Result<T>> + Send + 'static,
) -> anyhow::Result<T> {
    runtime().spawn(fut).await?
}

pub struct AppNodeConfig {
    pub data_dir: String,
    pub community_file: String,
    pub can_host: bool,
    pub livekit_bin: Option<String>,
}

pub struct AppVoiceCredentials {
    pub url: String,
    pub token: String,
    pub e2ee_key: Vec<u8>,
    pub host: String,
    pub term: u64,
    /// The ICE server the LiveKit client must use (relay-only): this node's TURN shim, which
    /// carries call media through the iroh connection. `None` if the machine has no usable
    /// network address; the app then refuses to join, because media has no other way to the host.
    pub ice: Option<AppIceServer>,
}

pub struct AppIceServer {
    /// `turn:<ip>:<port>?transport=udp`
    pub url: String,
    pub username: String,
    pub credential: String,
}

pub struct AppChannels {
    pub text: Vec<String>,
    pub voice: Vec<String>,
}

pub struct AppMember {
    /// The full member id, 64 hex characters.
    pub id: String,
    /// Its short tag, as shown next to the id.
    pub tag: String,
    pub name: String,
}

/// A text message. `(from, client_id)` names it, in history and in Text events alike: each
/// message is one Text event. Show messages in arrival order, which is the order history
/// returns and events come in. A history load can overlap the live events, so merge the two
/// by `(from, client_id)`. `(term, seq)` is not an id: it changes when a message is resent
/// after a hand-over, and terms start again at 1 when every node restarts.
pub struct AppTextMessage {
    pub channel: String,
    pub term: u64,
    pub seq: u64,
    /// The sender's full member id.
    pub from: String,
    pub sent_ms: u64,
    pub body: String,
    /// What `node_send_text` returned to the sender. 0 only for a message stored before the
    /// store kept client ids; `node_send_text` never returns 0.
    pub client_id: u64,
}

/// One member in a voice channel, with their mute and deafen state.
pub struct AppVoicePresence {
    /// The member's full id.
    pub member: String,
    pub channel: String,
    pub muted: bool,
    pub deafened: bool,
}

fn app_presence(p: VoicePresence) -> AppVoicePresence {
    AppVoicePresence { member: p.member.to_string(), channel: p.channel, muted: p.muted, deafened: p.deafened }
}

pub enum AppNodeEvent {
    HostChanged { host: Option<String>, term: u64, is_me: bool },
    PeerUp { member: String, direct: bool },
    PeerDown { member: String },
    Text { message: AppTextMessage },
    /// Someone joined, or a member's name or hosting ability changed; re-read `node_members`.
    MembersChanged,
    /// Everyone in a voice channel, as a full list: replace what was shown.
    VoiceRoster { entries: Vec<AppVoicePresence> },
}

/// The app's view of a node event.
fn app_event(ev: NodeEvent) -> Option<AppNodeEvent> {
    Some(match ev {
            NodeEvent::HostChanged { host, term, is_me } => {
                AppNodeEvent::HostChanged { host: host.map(|h| h.to_string()), term, is_me }
            }
            NodeEvent::PeerUp { member, kind } => AppNodeEvent::PeerUp {
                member: member.to_string(),
                direct: kind == ConnKind::Direct,
            },
            NodeEvent::PeerDown { member } => AppNodeEvent::PeerDown { member: member.to_string() },
            NodeEvent::Text { channel, term, seq, from, sent_ms, body, client_id } => AppNodeEvent::Text {
                message: AppTextMessage { channel, term, seq, from: from.to_string(), sent_ms, body, client_id },
            },
            NodeEvent::MembersChanged => AppNodeEvent::MembersChanged,
            NodeEvent::VoiceRoster { entries } => {
                AppNodeEvent::VoiceRoster { entries: entries.into_iter().map(app_presence).collect() }
            }
    })
}

#[frb(opaque)]
pub struct AppNode {
    node: Arc<Node>,
    /// Subscribed inside `start_node`, so no event emitted after `Node::start` is lost
    /// before Dart attaches its stream.
    events: Mutex<Option<broadcast::Receiver<NodeEvent>>>,
}

/// The current host as an event, to seed a late listener. None while there is no host.
fn seed_event(state: HostState, me: MemberId) -> Option<AppNodeEvent> {
    let host = state.host?;
    Some(AppNodeEvent::HostChanged {
        host: Some(host.to_string()),
        term: state.term,
        is_me: host == me,
    })
}

pub async fn start_node(cfg: AppNodeConfig) -> anyhow::Result<AppNode> {
    on_runtime(async move {
        let data_dir = PathBuf::from(&cfg.data_dir);
        let media: Box<dyn MediaHost> = match cfg.livekit_bin {
            Some(bin) => {
                let work_dir = data_dir.join("livekit");
                std::fs::create_dir_all(&work_dir)?;
                Box::new(LiveKitHost::new(PathBuf::from(bin), work_dir, LkPorts::default()))
            }
            None => Box::new(NoMediaHost),
        };
        let node_cfg = NodeConfig {
            data_dir,
            community_file: PathBuf::from(cfg.community_file),
            can_host: cfg.can_host,
            relay: RelayChoice::N0Default,
        };
        let node = Node::start(node_cfg, media).await?;
        let events = Mutex::new(Some(node.subscribe()));
        Ok(AppNode { node: Arc::new(node), events })
    })
    .await
}

#[frb(sync)]
pub fn node_member_id(n: &AppNode) -> String {
    n.node.member_id().to_string()
}

/// Short tag of this node's id, shown next to the full id.
#[frb(sync)]
pub fn node_member_tag(n: &AppNode) -> String {
    n.node.member_id().tag()
}

#[frb(sync)]
pub fn node_events(n: &AppNode, sink: StreamSink<AppNodeEvent>) -> anyhow::Result<()> {
    let mut rx = n
        .events
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow::anyhow!("node events already taken"))?;
    // State read after the receiver exists: anything newer arrives on `rx`.
    if let Some(ev) = seed_event(n.node.host_state(), n.node.member_id()) {
        let _ = sink.add(ev);
    }
    let roster = n.node.voice_roster();
    if !roster.is_empty() {
        let _ = sink.add(AppNodeEvent::VoiceRoster { entries: roster.into_iter().map(app_presence).collect() });
    }
    runtime().spawn(async move {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if let Some(ev) = app_event(ev) {
                        if sink.add(ev).is_err() {
                            break;
                        }
                    }
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

pub async fn node_voice_credentials(n: &AppNode, room: String) -> anyhow::Result<AppVoiceCredentials> {
    let node = &n.node;
    // `voice_credentials` borrows the node, so it cannot be spawned; the node's
    // own tasks already live on the node runtime.
    let c = node.voice_credentials(&room).await?;
    Ok(AppVoiceCredentials {
        url: c.url,
        token: c.token,
        e2ee_key: c.e2ee_key.to_vec(),
        host: c.host.to_string(),
        term: c.term,
        ice: c.ice.map(|i| AppIceServer { url: i.url, username: i.username, credential: i.credential }),
    })
}

#[frb(sync)]
pub fn node_channels(n: &AppNode) -> AppChannels {
    let c = n.node.channels();
    AppChannels { text: c.text, voice: c.voice }
}

/// Tells every member where this node is in voice. `channel` null means in none.
#[frb(sync)]
pub fn node_set_voice(n: &AppNode, channel: Option<String>, muted: bool, deafened: bool) {
    n.node.set_voice(channel, muted, deafened);
}

/// Who is in which voice channel now, as this node shows it.
#[frb(sync)]
pub fn node_voice_roster(n: &AppNode) -> Vec<AppVoicePresence> {
    n.node.voice_roster().into_iter().map(app_presence).collect()
}

/// Every member of the community, this node included.
#[frb(sync)]
pub fn node_members(n: &AppNode) -> Vec<AppMember> {
    n.node
        .members()
        .into_iter()
        .map(|(id, name)| AppMember { id: id.to_string(), tag: id.tag(), name })
        .collect()
}

/// Sends a text message and returns its client id. Without a host it waits and goes out
/// when one appears; its Text event arrives once the host has delivered it.
pub async fn node_send_text(n: &AppNode, channel: String, body: String) -> anyhow::Result<u64> {
    n.node.send_text(&channel, &body).await
}

/// The last `limit` stored messages of `channel`, in arrival order.
pub async fn node_text_history(n: &AppNode, channel: String, limit: u32) -> anyhow::Result<Vec<AppTextMessage>> {
    let stored = n.node.text_history(&channel, limit as usize)?;
    Ok(history_messages(&channel, stored))
}

/// History as app messages.
fn history_messages(channel: &str, stored: Vec<TextMessage>) -> Vec<AppTextMessage> {
    stored
        .into_iter()
        .map(|m| AppTextMessage {
            channel: channel.to_string(),
            term: m.term,
            seq: m.seq,
            from: m.from.to_string(),
            sent_ms: m.sent_ms,
            body: m.body,
            client_id: m.client_id,
        })
        .collect()
}

pub async fn node_shutdown(n: AppNode) {
    // A node of the hub is stopped by `hub_shutdown`/`hub_leave`; this stops a standalone one.
    let _ = runtime().spawn(async move { n.node.shutdown_ref().await }).await;
}

/// The server's name.
#[frb(sync)]
pub fn node_community_name(n: &AppNode) -> String {
    n.node.community_name()
}

/// A signed invite link to this server. 0 for `expires_min` or `max_uses` means never and
/// unlimited; `max_uses` above 255 counts as 255.
#[frb(sync)]
pub fn node_invite_create(n: &AppNode, expires_min: u32, max_uses: u32) -> String {
    n.node.invite_create(expires_min, max_uses.min(255) as u8)
}

/// Revokes `link` for the whole server.
#[frb(sync)]
pub fn node_invite_revoke(n: &AppNode, link: String) -> anyhow::Result<()> {
    n.node.invite_revoke(&link)
}

// ---- the hub: the profile and every server ----

/// One server this device is in.
pub struct AppCommunity {
    pub cid: String,
    pub name: String,
    pub is_owner: bool,
}

/// What an invite says, read without joining.
pub struct AppInvitePreview {
    pub cid: String,
    pub name: String,
    /// Minutes until it expires; 0 = never. An expired invite shows 1.
    pub expires_min: u32,
}

/// Progress of `hub_join`. The stream ends after `Denied` or `Joined`; any other failure
/// is the stream's error.
pub enum AppJoinEvent {
    Trying,
    Offline,
    Denied { reason: String },
    Joined { cid: String },
}

fn hub_slot() -> &'static Mutex<Option<Arc<Hub>>> {
    static HUB: Mutex<Option<Arc<Hub>>> = Mutex::new(None);
    &HUB
}

fn join_slot() -> &'static Mutex<Option<AbortHandle>> {
    static JOIN: Mutex<Option<AbortHandle>> = Mutex::new(None);
    &JOIN
}

fn hub() -> anyhow::Result<Arc<Hub>> {
    hub_slot().lock().unwrap().clone().ok_or_else(|| anyhow::anyhow!("the hub is not open"))
}

fn parse_cid(cid: &str) -> anyhow::Result<CommunityId> {
    cid.parse::<CommunityId>().map_err(|e| anyhow::anyhow!("bad server id: {e}"))
}

/// Opens the hub in `root` and starts every server in it. Call once.
pub async fn hub_open(root: String, can_host: bool, livekit_bin: Option<String>) -> anyhow::Result<()> {
    on_runtime(async move {
        ensure_closed()?;
        let cfg = HubConfig {
            can_host,
            relay: RelayChoice::N0Default,
            livekit_bin: livekit_bin.map(PathBuf::from),
        };
        let hub = Hub::open(std::path::Path::new(&root), cfg).await?;
        *hub_slot().lock().unwrap() = Some(Arc::new(hub));
        Ok(())
    })
    .await
}

fn ensure_closed() -> anyhow::Result<()> {
    anyhow::ensure!(hub_slot().lock().unwrap().is_none(), "the hub is already open");
    Ok(())
}

#[frb(sync)]
pub fn hub_member_id() -> anyhow::Result<String> {
    Ok(hub()?.member_id().to_string())
}

#[frb(sync)]
pub fn hub_member_tag() -> anyhow::Result<String> {
    Ok(hub()?.member_id().tag())
}

/// The name this device gives itself in servers it creates or joins.
#[frb(sync)]
pub fn profile_name() -> anyhow::Result<String> {
    Ok(hub()?.profile_name())
}

#[frb(sync)]
pub fn set_profile_name(name: String) -> anyhow::Result<()> {
    hub()?.set_profile_name(&name)
}

/// Every server this device is in.
#[frb(sync)]
pub fn hub_communities() -> anyhow::Result<Vec<AppCommunity>> {
    let hub = hub()?;
    Ok(hub
        .communities()
        .into_iter()
        .map(|(cid, name)| AppCommunity {
            is_owner: hub.node(&cid).is_some_and(|n| n.is_owner()),
            cid: cid.to_string(),
            name,
        })
        .collect())
}

/// A handle on the running server `cid`, with its own event stream (take it once with
/// `node_events`). The hub keeps running the node; do not `node_shutdown` it.
#[frb(sync)]
pub fn hub_node(cid: String) -> anyhow::Result<AppNode> {
    let node = hub()?.node(&parse_cid(&cid)?).ok_or_else(|| anyhow::anyhow!("not in server {cid}"))?;
    let events = Mutex::new(Some(node.subscribe()));
    Ok(AppNode { node, events })
}

/// Makes a server owned by this device and returns its id.
pub async fn community_create(name: String) -> anyhow::Result<String> {
    let hub = hub()?;
    on_runtime(async move { Ok(hub.create_community(&name).await?.to_string()) }).await
}

/// Reads an invite from pasted text without joining; None when it holds no invite.
#[frb(sync)]
pub fn invite_parse(text: String) -> Option<AppInvitePreview> {
    let invite = Invite::parse(&text).ok()?;
    Some(AppInvitePreview {
        cid: invite.cid.to_string(),
        name: invite.name.clone(),
        expires_min: minutes_left(invite.expires_min, now_min()),
    })
}

fn now_min() -> u32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    (secs / 60) as u32
}

/// Minutes from `now` to the absolute expiry `expires_min`; 0 stays "never".
fn minutes_left(expires_min: u32, now: u32) -> u32 {
    if expires_min == 0 { 0 } else { expires_min.saturating_sub(now).max(1) }
}

fn app_join_event(ev: JoinEvent) -> AppJoinEvent {
    match ev {
        JoinEvent::Trying => AppJoinEvent::Trying,
        JoinEvent::Offline => AppJoinEvent::Offline,
        JoinEvent::Denied(d) => AppJoinEvent::Denied { reason: d.to_string() },
        JoinEvent::Joined(cid) => AppJoinEvent::Joined { cid: cid.to_string() },
    }
}

/// Joins the server `link` invites to, reporting progress on `sink`. Starting another join
/// cancels the one running. The stream ends after Denied or Joined; any other failure is its
/// error. `hub_join_cancel` stops it with nothing saved.
#[frb(sync)]
pub fn hub_join(link: String, sink: StreamSink<AppJoinEvent>) -> anyhow::Result<()> {
    let hub = hub()?;
    let (tx, mut rx) = mpsc::unbounded_channel();
    let join = runtime().spawn(async move { hub.join(&link, tx).await });
    if let Some(old) = join_slot().lock().unwrap().replace(join.abort_handle()) {
        old.abort();
    }
    runtime().spawn(async move {
        while let Some(ev) = rx.recv().await {
            if sink.add(app_join_event(ev)).is_err() {
                join.abort();
                return;
            }
        }
        // The events are over: the join ended, failed, or was cancelled.
        if let Ok(Err(e)) = join.await {
            if e.downcast_ref::<Deny>().is_none() {
                let _ = sink.add_error(e);
            }
        }
    });
    Ok(())
}

/// Stops the running join, if any.
#[frb(sync)]
pub fn hub_join_cancel() {
    if let Some(join) = join_slot().lock().unwrap().take() {
        join.abort();
    }
}

/// Leaves a server on this device only.
pub async fn hub_leave(cid: String) -> anyhow::Result<()> {
    let hub = hub()?;
    let cid = parse_cid(&cid)?;
    on_runtime(async move { hub.leave(&cid).await }).await
}

/// Stops every server and the endpoint. Safe to call twice.
pub async fn hub_shutdown() {
    hub_join_cancel();
    let Some(hub) = hub_slot().lock().unwrap().take() else { return };
    let _ = runtime().spawn(async move { hub.shutdown().await }).await;
}

#[frb(sync)]
pub fn process_cpu_percent() -> f32 {
    static SYS: Mutex<Option<System>> = Mutex::new(None);
    let Ok(pid) = get_current_pid() else { return 0.0 };
    let mut guard = SYS.lock().unwrap();
    let sys = guard.get_or_insert_with(System::new);
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[pid]), true, ProcessRefreshKind::nothing().with_cpu());
    sys.process(pid).map(|p| p.cpu_usage()).unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_event_reports_current_host_for_late_listeners() {
        let me = MemberId([1; 32]);
        let other = MemberId([2; 32]);
        assert!(seed_event(HostState { host: None, term: 0 }, me).is_none());
        let Some(AppNodeEvent::HostChanged { host, term, is_me }) =
            seed_event(HostState { host: Some(other), term: 3 }, me)
        else {
            panic!("expected HostChanged");
        };
        assert_eq!((host, term, is_me), (Some(other.to_string()), 3, false));
        let Some(AppNodeEvent::HostChanged { is_me, .. }) =
            seed_event(HostState { host: Some(me), term: 1 }, me)
        else {
            panic!("expected HostChanged");
        };
        assert!(is_me);
    }

    #[test]
    fn voice_roster_reaches_the_app() {
        let m = MemberId([9; 32]);
        let ev = NodeEvent::VoiceRoster {
            entries: vec![VoicePresence { member: m, channel: "lobby".into(), muted: true, deafened: false }],
        };
        let Some(AppNodeEvent::VoiceRoster { entries }) = app_event(ev) else { panic!("expected VoiceRoster") };
        assert_eq!(entries.len(), 1);
        assert_eq!((entries[0].member.clone(), entries[0].channel.as_str()), (m.to_string(), "lobby"));
        assert!(entries[0].muted && !entries[0].deafened);
    }

    #[test]
    fn members_changed_reaches_the_app() {
        assert!(matches!(app_event(NodeEvent::MembersChanged), Some(AppNodeEvent::MembersChanged)));
    }

    #[test]
    fn invite_expiry_is_minutes_left() {
        assert_eq!(minutes_left(0, 500), 0);
        assert_eq!(minutes_left(560, 500), 60);
        assert_eq!(minutes_left(400, 500), 1);
    }

    #[test]
    fn join_events_carry_ids_and_reasons() {
        let cid = CommunityId::random();
        let AppJoinEvent::Joined { cid: got } = app_join_event(JoinEvent::Joined(cid)) else { panic!() };
        assert_eq!(got, cid.to_string());
        let AppJoinEvent::Denied { reason } = app_join_event(JoinEvent::Denied(Deny::Revoked)) else { panic!() };
        assert_eq!(reason, Deny::Revoked.to_string());
        assert!(matches!(app_join_event(JoinEvent::Offline), AppJoinEvent::Offline));
    }

    #[test]
    fn invite_parse_ignores_text_without_an_invite() {
        assert!(invite_parse("hello there".into()).is_none());
        assert!(matches!(hub(), Err(_)));
    }

    #[test]
    fn text_events_and_history_carry_the_full_sender_id() {
        let from = MemberId([0xab; 32]);
        let ev = NodeEvent::Text {
            channel: "general".into(),
            term: 2,
            seq: 5,
            from,
            sent_ms: 9,
            body: "hi".into(),
            client_id: 77,
        };
        let AppNodeEvent::Text { message } = app_event(ev).unwrap() else { panic!("expected Text") };
        assert_eq!((message.channel.as_str(), message.term, message.seq), ("general", 2, 5));
        assert_eq!((message.from, message.body.as_str(), message.client_id), (from.to_string(), "hi", 77));

        let stored = vec![TextMessage { term: 1, seq: 3, from, client_id: 55, sent_ms: 4, body: "old".into() }];
        let history = history_messages("games", stored);
        assert_eq!((history[0].channel.as_str(), history[0].seq, history[0].client_id), ("games", 3, 55));
        assert_eq!(history[0].from, from.to_string());
    }
}
