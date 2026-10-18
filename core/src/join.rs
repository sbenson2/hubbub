//! Joining a server with an invite link.
//!
//! Every hub runs a *door*: a second iroh endpoint whose key is derived from the identity
//! (`Identity::door_secret`) and that accepts only `hubbub/join/1`. With relays on it has no IP
//! transports, so a stranger holding a link reaches a member through the relay and never
//! learns the member's address. Any member's door can admit a joiner: it checks the invite
//! against its own state, admits the joiner (which broadcasts the new state to the members
//! online), and only then replies with the full state.
//!
//! A member admitted while another was offline is unknown to it. When the new member's control
//! dial is refused, it shows its signed entry chain on the per-server rejoin ALPN (`Rejoin`),
//! and the other side merges it like any state (see `Node::serve_rejoin`).
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use iroh::endpoint::{presets, Connection, VarInt};
use iroh::{Endpoint, EndpointAddr, RelayMode};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{sleep, sleep_until, timeout, Instant};

use crate::community::{clamp_name, CommunityState, MemberEntry, NewMember};
use crate::identity::Identity;
use crate::ids::{CommunityId, MemberId};
use crate::invite::{Deny, Invite};
use crate::net::{RelayChoice, Switch};
use crate::node::Node;
use crate::proto::{read_json, write_json, JOIN_ALPN};

/// The delay before dialing the 1st, 2nd and 3rd door of a link: the inviter's own door gets a
/// head start, and the others are tried only if it is slow.
pub const DOOR_STAGGER: [Duration; 3] = [Duration::ZERO, Duration::from_millis(1500), Duration::from_millis(3000)];
/// How long one door has to answer.
pub const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(10);
/// Time between the starts of two rounds of dialing the doors.
pub const RETRY_CYCLE: Duration = Duration::from_secs(20);
/// A door refuses connections beyond this many in a burst...
pub const DOOR_BURST: u32 = 10;
/// ...and earns this many back per minute.
pub const DOOR_PER_MINUTE: u32 = 10;
/// How long a door waits for a request, and for the joiner to take the reply.
const DOOR_IO_TIMEOUT: Duration = Duration::from_secs(10);

/// Timing of the joiner's dialing. The defaults are the constants above; tests shorten them.
#[derive(Clone, Copy, Debug)]
pub struct JoinTiming {
    pub stagger: [Duration; 3],
    pub attempt_timeout: Duration,
    pub cycle: Duration,
}

impl Default for JoinTiming {
    fn default() -> Self {
        JoinTiming { stagger: DOOR_STAGGER, attempt_timeout: ATTEMPT_TIMEOUT, cycle: RETRY_CYCLE }
    }
}

/// What `Hub::join` reports while it works.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JoinEvent {
    /// Dialing the link's doors (sent at the start of every round).
    Trying,
    /// No door answered during a round; another follows.
    Offline,
    /// A member refused the invite. Final.
    Denied(Deny),
    /// The server is joined and running on this hub. Final.
    Joined(CommunityId),
}

/// The messages of the join door and of the rejoin ALPN, as length-prefixed JSON frames.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum JoinMsg {
    /// To a door. `invite` is the link; `door` is the joiner's own door id, which becomes its
    /// entry's door. The joiner's member id is the id it dialed with.
    JoinRequest { cid: CommunityId, invite: String, name: String, can_host: bool, door: MemberId },
    /// The full state, secret included (the transport is QUIC/TLS keyed by member id).
    JoinAccepted { state: CommunityState },
    JoinDenied { reason: Deny },
    /// To a server's rejoin ALPN: the joiner's entry and its admitters', up to the owner's.
    Rejoin { cid: CommunityId, chain: Vec<MemberEntry> },
    /// `added`: the receiver had not heard of the sender before.
    RejoinOk { added: bool },
    RejoinRefused,
}

/// Whether the door drops its IP transports. With relays off (tests only) it keeps loopback so
/// the in-memory address book can reach it; otherwise it is relay-only.
pub fn door_clears_ip_transports(relay: RelayChoice) -> bool {
    relay != RelayChoice::Disabled
}

/// A token bucket: `capacity` at most, refilled at `per_minute`.
#[derive(Debug)]
pub struct TokenBucket {
    capacity: f64,
    tokens: f64,
    per_sec: f64,
    last: Instant,
}

impl TokenBucket {
    pub fn new(capacity: u32, per_minute: u32, now: Instant) -> Self {
        TokenBucket { capacity: capacity as f64, tokens: capacity as f64, per_sec: per_minute as f64 / 60.0, last: now }
    }

    /// Takes one token if there is one.
    pub fn try_take(&mut self, now: Instant) -> bool {
        let dt = now.saturating_duration_since(self.last).as_secs_f64();
        self.last = self.last.max(now);
        self.tokens = (self.tokens + dt * self.per_sec).min(self.capacity);
        if self.tokens >= 1.0 - 1e-9 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

/// Finds the node of a server on this hub.
pub(crate) type NodeLookup = Arc<dyn Fn(&CommunityId) -> Option<Arc<Node>> + Send + Sync>;

/// A hub's join door.
pub(crate) struct Door {
    endpoint: Endpoint,
    task: JoinHandle<()>,
}

impl Drop for Door {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Door {
    pub(crate) async fn start(identity: &Identity, relay: RelayChoice, nodes: NodeLookup) -> Result<Door> {
        let builder = match relay {
            RelayChoice::N0Default => Endpoint::builder(presets::N0),
            RelayChoice::Disabled => Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled),
        };
        let builder = if door_clears_ip_transports(relay) { builder.clear_ip_transports() } else { builder };
        let endpoint = builder
            .secret_key(identity.door_secret())
            .alpns(vec![JOIN_ALPN.to_vec()])
            .bind()
            .await
            .context("binding the join door")?;
        let bucket = TokenBucket::new(DOOR_BURST, DOOR_PER_MINUTE, Instant::now());
        let task = tokio::spawn(accept_loop(endpoint.clone(), nodes, bucket));
        Ok(Door { endpoint, task })
    }

    /// The door's loopback address, for same-machine tests.
    #[cfg(feature = "test-util")]
    pub(crate) fn addr(&self) -> EndpointAddr {
        crate::net::loopback_addr(&self.endpoint)
    }

    /// Stops accepting, drops the requests in flight and closes the endpoint.
    pub(crate) async fn close(&self) {
        self.task.abort();
        self.endpoint.close().await;
    }
}

async fn accept_loop(endpoint: Endpoint, nodes: NodeLookup, mut bucket: TokenBucket) {
    // Admissions are checked and made one at a time, so a use-limited invite is not overspent
    // by requests that arrive together. Dropping the set (on abort) ends every handler.
    let admitting = Arc::new(Mutex::new(()));
    let mut handlers = JoinSet::new();
    while let Some(incoming) = endpoint.accept().await {
        while handlers.try_join_next().is_some() {}
        if !bucket.try_take(Instant::now()) {
            incoming.refuse();
            continue;
        }
        let (nodes, admitting) = (nodes.clone(), admitting.clone());
        handlers.spawn(async move {
            let Ok(accepting) = incoming.accept() else { return };
            let Ok(conn) = accepting.await else { return };
            if conn.alpn() != JOIN_ALPN {
                conn.close(VarInt::from_u32(403), b"403");
                return;
            }
            let _ = timeout(DOOR_IO_TIMEOUT, serve_request(&conn, &nodes, &admitting)).await;
            conn.close(VarInt::from_u32(0), b"done");
        });
    }
}

async fn serve_request(conn: &Connection, nodes: &NodeLookup, admitting: &Mutex<()>) -> Result<()> {
    let from = MemberId(*conn.remote_id().as_bytes());
    let (mut send, mut recv) = conn.accept_bi().await?;
    let Some(JoinMsg::JoinRequest { cid, invite, name, can_host, door }) = read_json(&mut recv).await? else {
        bail!("expected JoinRequest");
    };
    // A hub that is not in this server says nothing, so the joiner tries another door.
    let Some(node) = nodes(&cid) else { bail!("not in server {cid}") };
    let reply = {
        let _one_at_a_time = admitting.lock().unwrap();
        answer(&node, from, &invite, name, can_host, door)
    };
    write_json(&mut send, &reply).await?;
    let _ = send.finish();
    // Let the joiner read the reply before the connection goes.
    conn.closed().await;
    Ok(())
}

/// The member side of a join: verify the invite against this node's state, admit (which tells
/// the members online), and reply. A member asking again is accepted again, using nothing up.
fn answer(node: &Node, from: MemberId, link: &str, name: String, can_host: bool, door: MemberId) -> JoinMsg {
    let state = node.state();
    if state.is_member(&from) {
        return JoinMsg::JoinAccepted { state: (*state).clone() };
    }
    let invite = match Invite::parse(link) {
        Ok(i) => i,
        Err(_) => return JoinMsg::JoinDenied { reason: Deny::BadSignature },
    };
    if let Err(reason) = invite.verify(&state) {
        return JoinMsg::JoinDenied { reason };
    }
    let new = NewMember { id: from, name: clamp_name(&name), can_host, door, via_invite: Some(invite.invite_id) };
    if node.admit(new).is_err() {
        return JoinMsg::JoinDenied { reason: Deny::UnknownInviter };
    }
    JoinMsg::JoinAccepted { state: (*node.state()).clone() }
}

/// The joiner's side: asks the link's doors, staggered, round after round, until one answers.
/// `Ok(state)` is the full state with this device already a member; `Err(deny)` is a member's
/// refusal. Sends `Trying` and `Offline` on `events`. Nothing is kept running when the future is
/// dropped, which is how a join is cancelled.
pub(crate) async fn request(
    switch: &Arc<Switch>,
    identity: &Identity,
    invite: &Invite,
    link: &str,
    name: &str,
    can_host: bool,
    timing: JoinTiming,
    events: &mpsc::UnboundedSender<JoinEvent>,
) -> Result<std::result::Result<CommunityState, Deny>> {
    let msg = JoinMsg::JoinRequest {
        cid: invite.cid,
        invite: link.to_string(),
        name: name.to_string(),
        can_host,
        door: identity.door_id(),
    };
    loop {
        let _ = events.send(JoinEvent::Trying);
        let started = Instant::now();
        let mut round = JoinSet::new();
        for (i, door) in invite.doors.iter().enumerate() {
            let (switch, msg) = (switch.clone(), msg.clone());
            let (door, delay) = (*door, timing.stagger[i.min(2)]);
            let (cid, me) = (invite.cid, identity.member_id());
            round.spawn(async move {
                sleep(delay).await;
                timeout(timing.attempt_timeout, ask(&switch, door, &msg, cid, me)).await.context("door timed out")?
            });
        }
        while let Some(done) = round.join_next().await {
            if let Ok(Ok(answer)) = done {
                return Ok(answer);
            }
        }
        let _ = events.send(JoinEvent::Offline);
        sleep_until(started + timing.cycle).await;
    }
}

async fn ask(
    switch: &Switch,
    door: MemberId,
    msg: &JoinMsg,
    cid: CommunityId,
    me: MemberId,
) -> Result<std::result::Result<CommunityState, Deny>> {
    let key = iroh::PublicKey::from_bytes(&door.0).context("invalid door id")?;
    let conn = switch.connect_raw(EndpointAddr::new(key), JOIN_ALPN).await?;
    let (mut send, mut recv) = conn.open_bi().await?;
    write_json(&mut send, msg).await?;
    let reply: Option<JoinMsg> = read_json(&mut recv).await?;
    conn.close(VarInt::from_u32(0), b"done");
    match reply {
        Some(JoinMsg::JoinDenied { reason }) => Ok(Err(reason)),
        Some(JoinMsg::JoinAccepted { state }) => {
            // Trust nothing the door says that the state itself cannot back up.
            ensure!(state.id == cid && state.id_matches_owner(), "door sent the wrong server");
            ensure!(state.secret_hex.is_some(), "door sent no secret");
            ensure!(state.member(&me).is_some_and(|e| state.verify_entry(e)), "door did not admit us");
            Ok(Ok(state))
        }
        other => bail!("unexpected reply from the door: {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_allows_a_burst_then_refills() {
        let t0 = Instant::now();
        let mut b = TokenBucket::new(10, 10, t0);
        assert!((0..10).all(|_| b.try_take(t0)));
        assert!(!b.try_take(t0), "the 11th inside the minute is refused");
        assert!(!b.try_take(t0 + Duration::from_secs(5)));
        assert!(b.try_take(t0 + Duration::from_secs(6)), "one token per 6 s");
        assert!(!b.try_take(t0 + Duration::from_secs(6)));
        // Never more than the capacity, however long it idles.
        let later = t0 + Duration::from_secs(3600);
        assert_eq!((0..20).filter(|_| b.try_take(later)).count(), 10);
    }

    #[test]
    fn door_is_relay_only_unless_relays_are_off() {
        assert!(door_clears_ip_transports(RelayChoice::N0Default));
        assert!(!door_clears_ip_transports(RelayChoice::Disabled));
    }
}
