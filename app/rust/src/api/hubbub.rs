//! Flutter-facing API over `hubbub-core`. Node work runs on a dedicated
//! multi-thread tokio runtime because iroh needs one.
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use hubbub_core::media_host::{LiveKitHost, LkPorts, MediaHost, NoMediaHost};
use hubbub_core::net::{ConnKind, RelayChoice};
use hubbub_core::node::{Node, NodeConfig, NodeEvent};
use sysinfo::{get_current_pid, ProcessRefreshKind, ProcessesToUpdate, System};
use hubbub_core::election::HostState;
use hubbub_core::ids::MemberId;
use hubbub_core::text::TextMessage;
use tokio::sync::broadcast::{self, error::RecvError};

use crate::frb_generated::StreamSink;

fn runtime() -> &'static tokio::runtime::Runtime {
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

pub enum AppNodeEvent {
    HostChanged { host: Option<String>, term: u64, is_me: bool },
    PeerUp { member: String, direct: bool },
    PeerDown { member: String },
    Text { message: AppTextMessage },
}

/// The app's view of a node event; None for events the app does not carry yet
/// (`MembersChanged` until the hub API adds it).
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
            NodeEvent::MembersChanged => return None,
    })
}

#[frb(opaque)]
pub struct AppNode {
    node: Node,
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
        Ok(AppNode { node, events })
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
    })
}

#[frb(sync)]
pub fn node_channels(n: &AppNode) -> AppChannels {
    let c = n.node.channels();
    AppChannels { text: c.text, voice: c.voice }
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
    let _ = runtime().spawn(async move { n.node.shutdown().await }).await;
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
