//! Member-only Iroh networking: only keys in a community's live member list get through,
//! and only on that community's own ALPNs.
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use iroh::endpoint::{presets, Connection, VarInt};
use iroh::address_lookup::MemoryLookup;
use iroh::{Endpoint, EndpointAddr, RelayMode};
use tokio::sync::{mpsc, watch};

use crate::community::CommunityState;
use crate::identity::Identity;
use crate::ids::MemberId;
use crate::proto::{ctl_alpn, media_alpn, rejoin_alpn, sig_alpn, CTL_PREFIX, REJOIN_PREFIX};

/// Application close code for a connection from a non-member or with an unknown ALPN.
const CLOSE_FORBIDDEN: u32 = 403;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RelayChoice {
    /// n0's public relays and discovery (spike only).
    N0Default,
    /// No relays, no discovery: direct addresses only (tests).
    Disabled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum ConnKind {
    Direct,
    Relay,
    Unknown,
}

type Accepted = (MemberId, Vec<u8>, Connection);

/// One community's route on a shared endpoint.
#[derive(Clone)]
struct Route {
    community: watch::Receiver<Arc<CommunityState>>,
    conns: Arc<Mutex<HashMap<MemberId, Connection>>>,
    /// Every connection of this community, either direction, so `Net::close` can end them.
    live: Arc<Mutex<Vec<Connection>>>,
    tx: mpsc::Sender<Accepted>,
}

/// One iroh endpoint serving any number of communities. It accepts exactly the ALPNs of the
/// communities registered on it and hands each connection to that community's live
/// membership check. A `Hub` owns one for all its servers; a standalone `Net` owns a private one.
pub struct Switch {
    endpoint: Endpoint,
    routes: Arc<Mutex<HashMap<Vec<u8>, Route>>>,
    /// Peer addresses for same-machine tests, where there is no address lookup service.
    lookup: MemoryLookup,
    id: MemberId,
    accept_task: tokio::task::JoinHandle<()>,
}

impl Drop for Switch {
    fn drop(&mut self) {
        self.accept_task.abort();
    }
}

impl Switch {
    pub async fn bind(id: &Identity, relay: RelayChoice) -> Result<Switch> {
        let builder = match relay {
            RelayChoice::N0Default => Endpoint::builder(presets::N0),
            RelayChoice::Disabled => Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled),
        };
        let lookup = MemoryLookup::new();
        let endpoint = builder
            .secret_key(id.secret_key())
            .address_lookup(lookup.clone())
            .alpns(Vec::new())
            .bind()
            .await
            .context("binding iroh endpoint")?;
        let routes: Arc<Mutex<HashMap<Vec<u8>, Route>>> = Arc::default();
        let accept_task = tokio::spawn(accept_loop(endpoint.clone(), routes.clone()));
        Ok(Switch { endpoint, routes, lookup, id: id.member_id(), accept_task })
    }

    pub fn member_id(&self) -> MemberId {
        self.id
    }

    /// Starts serving `community`'s ALPN pair and returns its view of this endpoint.
    pub fn register(self: &Arc<Self>, community: watch::Receiver<Arc<CommunityState>>) -> Net {
        let cid = community.borrow().id;
        let (ctl, sig, media, rejoin) = (ctl_alpn(&cid), sig_alpn(&cid), media_alpn(&cid), rejoin_alpn(&cid));
        let (tx, rx) = mpsc::channel(32);
        let route = Route { community, conns: Arc::default(), live: Arc::default(), tx };
        {
            let mut routes = self.routes.lock().unwrap();
            routes.insert(ctl.clone(), route.clone());
            routes.insert(sig.clone(), route.clone());
            routes.insert(media.clone(), route.clone());
            routes.insert(rejoin.clone(), route.clone());
            self.endpoint.set_alpns(routes.keys().cloned().collect());
        }
        Net { switch: self.clone(), owns: false, ctl, sig, media, rejoin, route, incoming: tokio::sync::Mutex::new(rx) }
    }

    /// Stops serving a community, but only if `route` is still the registered one.
    fn unregister(&self, ctl: &[u8], sig: &[u8], media: &[u8], rejoin: &[u8], route: &Route) {
        let mut routes = self.routes.lock().unwrap();
        let ours = routes.get(ctl).is_some_and(|r| Arc::ptr_eq(&r.live, &route.live));
        if ours {
            routes.remove(ctl);
            routes.remove(sig);
            routes.remove(media);
            routes.remove(rejoin);
            self.endpoint.set_alpns(routes.keys().cloned().collect());
        }
    }

    /// Teach the endpoint where to find a peer (tests; real peers use address lookup).
    pub fn add_peer_addr(&self, addr: EndpointAddr) {
        self.lookup.add_endpoint_info(addr);
    }

    /// This endpoint's address for same-machine tests: its id plus loopback
    /// addresses on the bound ports.
    pub fn addr(&self) -> EndpointAddr {
        loopback_addr(&self.endpoint)
    }

    /// The ALPNs currently accepted, sorted.
    pub fn alpns(&self) -> Vec<Vec<u8>> {
        let mut v: Vec<Vec<u8>> = self.routes.lock().unwrap().keys().cloned().collect();
        v.sort();
        v
    }

    /// Dial `to` with an arbitrary ALPN, outside any community (tests of refusal).
    pub async fn connect_raw(&self, to: EndpointAddr, alpn: &[u8]) -> Result<Connection> {
        self.endpoint.connect(to, alpn).await.context("connecting")
    }

    /// Close the endpoint and every connection on it.
    pub async fn close(&self) {
        self.endpoint.close().await;
    }
}

/// `endpoint`'s id plus loopback addresses on its bound ports (same-machine tests).
pub(crate) fn loopback_addr(endpoint: &Endpoint) -> EndpointAddr {
    let mut addr = EndpointAddr::new(endpoint.id());
    for s in endpoint.bound_sockets() {
        let loopback: std::net::IpAddr = match s {
            std::net::SocketAddr::V4(_) => std::net::Ipv4Addr::LOCALHOST.into(),
            std::net::SocketAddr::V6(_) => std::net::Ipv6Addr::LOCALHOST.into(),
        };
        addr = addr.with_ip_addr(std::net::SocketAddr::new(loopback, s.port()));
    }
    addr
}

/// A community's view of an endpoint: its ALPN pair, its accepted connections, its dials.
pub struct Net {
    switch: Arc<Switch>,
    /// Whether the endpoint is private to this net, so `close` may close it.
    owns: bool,
    ctl: Vec<u8>,
    sig: Vec<u8>,
    media: Vec<u8>,
    rejoin: Vec<u8>,
    route: Route,
    incoming: tokio::sync::Mutex<mpsc::Receiver<Accepted>>,
}

impl Drop for Net {
    fn drop(&mut self) {
        self.switch.unregister(&self.ctl, &self.sig, &self.media, &self.rejoin, &self.route);
    }
}

impl Net {
    /// A net on a private endpoint (single-community nodes and tests).
    /// `community` is the live membership: a member admitted later gets through at once.
    pub async fn bind(id: &Identity, community: watch::Receiver<Arc<CommunityState>>, relay: RelayChoice) -> Result<Net> {
        let switch = Arc::new(Switch::bind(id, relay).await?);
        let mut net = switch.register(community);
        net.owns = true;
        Ok(net)
    }

    pub fn member_id(&self) -> MemberId {
        self.switch.id
    }

    /// This community's control ALPN.
    pub fn ctl_alpn(&self) -> &[u8] {
        &self.ctl
    }

    /// This community's LiveKit signal-tunnel ALPN.
    pub fn sig_alpn(&self) -> &[u8] {
        &self.sig
    }

    /// This community's media-tunnel ALPN (call media as QUIC datagrams).
    pub fn media_alpn(&self) -> &[u8] {
        &self.media
    }

    /// This community's rejoin ALPN, open to members the others have not yet heard of.
    pub fn rejoin_alpn(&self) -> &[u8] {
        &self.rejoin
    }

    /// The endpoint's loopback address, for same-machine tests.
    pub async fn addr(&self) -> Result<EndpointAddr> {
        Ok(self.switch.addr())
    }

    /// Connect to a member by id, relying on iroh address lookup.
    pub async fn connect(&self, to: MemberId, alpn: &[u8]) -> Result<Connection> {
        let key = iroh::PublicKey::from_bytes(&to.0).context("invalid member public key")?;
        self.connect_addr(EndpointAddr::new(key), alpn).await
    }

    pub async fn connect_addr(&self, to: EndpointAddr, alpn: &[u8]) -> Result<Connection> {
        let member = MemberId(*to.id.as_bytes());
        let conn = self.switch.endpoint.connect(to, alpn).await.context("connecting")?;
        if alpn == self.ctl {
            self.route.conns.lock().unwrap().insert(member, conn.clone());
        }
        track(&self.route, &conn);
        Ok(conn)
    }

    /// Close this community's connections gracefully, so peers see the close instead of a
    /// timeout. A net on a private endpoint closes the endpoint; one on a shared endpoint
    /// leaves it, and the other communities, alone and stops serving its ALPNs.
    pub async fn close(&self) {
        if self.owns {
            self.switch.close().await;
            return;
        }
        self.switch.unregister(&self.ctl, &self.sig, &self.media, &self.rejoin, &self.route);
        let live = std::mem::take(&mut *self.route.live.lock().unwrap());
        for c in live {
            c.close(VarInt::from_u32(0), b"bye");
        }
    }

    /// Next connection from a member with a known ALPN; `None` once the endpoint is closed.
    pub async fn accept(&self) -> Option<Accepted> {
        self.incoming.lock().await.recv().await
    }

    /// Whether the newest control connection to `to` currently selects a direct path.
    /// Only control connections count: a short-lived signal connection must not mask it.
    pub fn conn_kind(&self, to: MemberId) -> ConnKind {
        let conns = self.route.conns.lock().unwrap();
        let Some(conn) = conns.get(&to) else { return ConnKind::Unknown };
        if conn.close_reason().is_some() {
            return ConnKind::Unknown;
        }
        match conn.paths().iter().find(|p| p.is_selected()) {
            Some(p) if p.is_ip() => ConnKind::Direct,
            Some(p) if p.is_relay() => ConnKind::Relay,
            _ => ConnKind::Unknown,
        }
    }
}

fn track(route: &Route, conn: &Connection) {
    let mut live = route.live.lock().unwrap();
    live.retain(|c| c.close_reason().is_none());
    live.push(conn.clone());
}

async fn accept_loop(endpoint: Endpoint, routes: Arc<Mutex<HashMap<Vec<u8>, Route>>>) {
    while let Some(incoming) = endpoint.accept().await {
        let routes = routes.clone();
        // Handshake each connection on its own task so a slow peer cannot stall the rest.
        tokio::spawn(async move {
            let Ok(accepting) = incoming.accept() else { return };
            let Ok(conn) = accepting.await else { return };
            let who = MemberId(*conn.remote_id().as_bytes());
            let alpn = conn.alpn().to_vec();
            // Looked up after the handshake: a community left meanwhile is refused here.
            let route = routes.lock().unwrap().get(&alpn).cloned();
            let Some(route) = route else {
                conn.close(VarInt::from_u32(CLOSE_FORBIDDEN), b"403");
                return;
            };
            // The rejoin ALPN is how a not-yet-known member proves itself; the node checks it.
            if !alpn.starts_with(REJOIN_PREFIX) && !route.community.borrow().is_member(&who) {
                conn.close(VarInt::from_u32(CLOSE_FORBIDDEN), b"403");
                return;
            }
            if alpn.starts_with(CTL_PREFIX) {
                route.conns.lock().unwrap().insert(who, conn.clone());
            }
            track(&route, &conn);
            let _ = route.tx.send((who, alpn, conn)).await;
        });
    }
}

#[cfg(any(test, feature = "test-util"))]
pub mod test_support {
    use super::*;
    async fn bind_in_tempdir(id: &Identity, community: &Arc<CommunityState>) -> Net {
        // The sender may go: a receiver still reads the last value.
        Net::bind(id, watch::channel(community.clone()).1, RelayChoice::Disabled).await.unwrap()
    }

    /// Two nets that belong to one shared community, with no relays.
    pub async fn two_member_nets() -> (Net, Net) {
        let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (ia, ib) = (Identity::load_or_create(da.path()).unwrap(), Identity::load_or_create(db.path()).unwrap());
        let c = Arc::new(CommunityState::for_tests("test", &[(&ia, "a", true), (&ib, "b", true)]));
        (bind_in_tempdir(&ia, &c).await, bind_in_tempdir(&ib, &c).await)
    }

    /// A net whose identity is not in the community of `two_member_nets`.
    pub async fn stranger_net() -> Net {
        let d = tempfile::tempdir().unwrap();
        let id = Identity::load_or_create(d.path()).unwrap();
        let c = CommunityState::for_tests("stranger-view", &[(&id, "stranger", true)]);
        bind_in_tempdir(&id, &Arc::new(c)).await
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::test_support::*;
    use super::*;
    use crate::proto::{read_msg, write_msg, CtlMsg};

    #[tokio::test]
    async fn member_connects_and_exchanges_msg() {
        let (a, b) = two_member_nets().await;
        let conn = a.connect_addr(b.addr().await.unwrap(), a.ctl_alpn()).await.unwrap();
        let (mut s, _r) = conn.open_bi().await.unwrap();
        write_msg(&mut s, &CtlMsg::Ping { nonce: 7 }).await.unwrap();
        let (who, alpn, c) = b.accept().await.unwrap();
        assert_eq!(who, a.member_id());
        assert_eq!(alpn, b.ctl_alpn());
        let (_s2, mut r2) = c.accept_bi().await.unwrap();
        assert!(matches!(read_msg(&mut r2).await.unwrap(), Some(CtlMsg::Ping { nonce: 7 })));
        assert_eq!(a.conn_kind(b.member_id()), ConnKind::Direct);
    }

    #[tokio::test]
    async fn non_member_connection_is_rejected() {
        let (_a, b) = two_member_nets().await;
        let stranger = stranger_net().await;
        // Either the connect fails, or it succeeds and is closed with code 403.
        if let Ok(conn) = stranger.connect_addr(b.addr().await.unwrap(), b.ctl_alpn()).await {
            let err = tokio::time::timeout(Duration::from_secs(2), conn.closed())
                .await
                .expect("server must close the stranger's connection within 2 s");
            assert!(err.to_string().contains("403"), "unexpected close: {err}");
        }
        let accepted = tokio::time::timeout(Duration::from_millis(500), b.accept()).await;
        assert!(accepted.is_err(), "stranger must never be yielded by accept()");
    }

    #[tokio::test]
    async fn oversized_frame_is_an_error() {
        let (a, b) = two_member_nets().await;
        let conn = a.connect_addr(b.addr().await.unwrap(), a.ctl_alpn()).await.unwrap();
        let (mut s, _r) = conn.open_bi().await.unwrap();
        s.write_all(&65_537u32.to_be_bytes()).await.unwrap();
        let (_, _, c) = b.accept().await.unwrap();
        let (_s2, mut r2) = c.accept_bi().await.unwrap();
        assert!(read_msg(&mut r2).await.is_err());
    }
}
