//! Member-only Iroh networking: only keys listed in the community file get through.
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use iroh::endpoint::{presets, Connection, VarInt};
use iroh::{Endpoint, EndpointAddr, RelayMode};
use tokio::sync::{mpsc, watch};

use crate::community::CommunityState;
use crate::identity::Identity;
use crate::ids::MemberId;
use crate::proto::{ALPN_CTL, ALPN_LK_SIGNAL};

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

pub struct Net {
    id: MemberId,
    endpoint: Endpoint,
    conns: Arc<Mutex<HashMap<MemberId, Connection>>>,
    incoming: tokio::sync::Mutex<mpsc::Receiver<Accepted>>,
    accept_task: tokio::task::JoinHandle<()>,
}

impl Drop for Net {
    fn drop(&mut self) {
        self.accept_task.abort();
    }
}

impl Net {
    /// `community` is the live membership: a member admitted later gets through at once.
    pub async fn bind(id: &Identity, community: watch::Receiver<Arc<CommunityState>>, relay: RelayChoice) -> Result<Net> {
        let builder = match relay {
            RelayChoice::N0Default => Endpoint::builder(presets::N0),
            RelayChoice::Disabled => Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled),
        };
        let endpoint = builder
            .secret_key(id.secret_key())
            .alpns(vec![ALPN_CTL.to_vec(), ALPN_LK_SIGNAL.to_vec()])
            .bind()
            .await
            .context("binding iroh endpoint")?;
        let conns: Arc<Mutex<HashMap<MemberId, Connection>>> = Arc::default();
        let (tx, rx) = mpsc::channel(32);
        let accept_task = tokio::spawn(accept_loop(endpoint.clone(), community, conns.clone(), tx));
        Ok(Net {
            id: id.member_id(),
            endpoint,
            conns,
            incoming: tokio::sync::Mutex::new(rx),
            accept_task,
        })
    }

    pub fn member_id(&self) -> MemberId {
        self.id
    }

    /// This endpoint's address for same-machine tests: its id plus loopback
    /// addresses on the bound ports. Real peers find each other through iroh
    /// address lookup instead.
    pub async fn addr(&self) -> Result<EndpointAddr> {
        let mut addr = EndpointAddr::new(self.endpoint.id());
        for s in self.endpoint.bound_sockets() {
            let loopback: std::net::IpAddr = match s {
                std::net::SocketAddr::V4(_) => std::net::Ipv4Addr::LOCALHOST.into(),
                std::net::SocketAddr::V6(_) => std::net::Ipv6Addr::LOCALHOST.into(),
            };
            addr = addr.with_ip_addr(std::net::SocketAddr::new(loopback, s.port()));
        }
        Ok(addr)
    }

    /// Connect to a member by id, relying on iroh address lookup.
    pub async fn connect(&self, to: MemberId, alpn: &[u8]) -> Result<Connection> {
        let key = iroh::PublicKey::from_bytes(&to.0).context("invalid member public key")?;
        self.connect_addr(EndpointAddr::new(key), alpn).await
    }

    pub async fn connect_addr(&self, to: EndpointAddr, alpn: &[u8]) -> Result<Connection> {
        let member = MemberId(*to.id.as_bytes());
        let conn = self.endpoint.connect(to, alpn).await.context("connecting")?;
        if alpn == ALPN_CTL {
            self.conns.lock().unwrap().insert(member, conn.clone());
        }
        Ok(conn)
    }

    /// Close every connection gracefully, so peers see the close instead of a timeout.
    pub async fn close(&self) {
        self.endpoint.close().await;
    }

    /// Next connection from a member with a known ALPN; `None` once the endpoint is closed.
    pub async fn accept(&self) -> Option<Accepted> {
        self.incoming.lock().await.recv().await
    }

    /// Whether the newest control connection to `to` currently selects a direct path.
    /// Only `ALPN_CTL` connections count: a short-lived signal connection must not mask it.
    pub fn conn_kind(&self, to: MemberId) -> ConnKind {
        let conns = self.conns.lock().unwrap();
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

async fn accept_loop(
    endpoint: Endpoint,
    community: watch::Receiver<Arc<CommunityState>>,
    conns: Arc<Mutex<HashMap<MemberId, Connection>>>,
    tx: mpsc::Sender<Accepted>,
) {
    while let Some(incoming) = endpoint.accept().await {
        let community = community.clone();
        let conns = conns.clone();
        let tx = tx.clone();
        // Handshake each connection on its own task so a slow peer cannot stall the rest.
        tokio::spawn(async move {
            let Ok(accepting) = incoming.accept() else { return };
            let Ok(conn) = accepting.await else { return };
            let who = MemberId(*conn.remote_id().as_bytes());
            let alpn = conn.alpn().to_vec();
            let known_alpn = alpn == ALPN_CTL || alpn == ALPN_LK_SIGNAL;
            let member = community.borrow().is_member(&who);
            if !member || !known_alpn {
                conn.close(VarInt::from_u32(CLOSE_FORBIDDEN), b"403");
                return;
            }
            if alpn == ALPN_CTL {
                conns.lock().unwrap().insert(who, conn.clone());
            }
            let _ = tx.send((who, alpn, conn)).await;
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
        let conn = a.connect_addr(b.addr().await.unwrap(), ALPN_CTL).await.unwrap();
        let (mut s, _r) = conn.open_bi().await.unwrap();
        write_msg(&mut s, &CtlMsg::Ping { nonce: 7 }).await.unwrap();
        let (who, alpn, c) = b.accept().await.unwrap();
        assert_eq!(who, a.member_id());
        assert_eq!(alpn, ALPN_CTL);
        let (_s2, mut r2) = c.accept_bi().await.unwrap();
        assert!(matches!(read_msg(&mut r2).await.unwrap(), Some(CtlMsg::Ping { nonce: 7 })));
        assert_eq!(a.conn_kind(b.member_id()), ConnKind::Direct);
    }

    #[tokio::test]
    async fn non_member_connection_is_rejected() {
        let (_a, b) = two_member_nets().await;
        let stranger = stranger_net().await;
        // Either the connect fails, or it succeeds and is closed with code 403.
        if let Ok(conn) = stranger.connect_addr(b.addr().await.unwrap(), ALPN_CTL).await {
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
        let conn = a.connect_addr(b.addr().await.unwrap(), ALPN_CTL).await.unwrap();
        let (mut s, _r) = conn.open_bi().await.unwrap();
        s.write_all(&65_537u32.to_be_bytes()).await.unwrap();
        let (_, _, c) = b.accept().await.unwrap();
        let (_s2, mut r2) = c.accept_bi().await.unwrap();
        assert!(read_msg(&mut r2).await.is_err());
    }
}
