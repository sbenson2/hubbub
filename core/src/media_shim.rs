//! The member-side TURN server that gets call media into the tunnel.
//!
//! libwebrtc (the engine under flutter_webrtc) will not use loopback candidates, and LiveKit
//! listens on loopback only. So each node runs a minimal TURN server on its own LAN address
//! and the app gives it to LiveKit's client as the one ICE server. The client's relayed
//! candidate is then an allocation here; every packet on it becomes a frame on the media
//! tunnel (`media_tunnel`), toward the host's LiveKit. No traffic leaves the machine except
//! through iroh, and the server is reachable only from this machine's own address.
//!
//! The server is webrtc-rs's `turn` crate (MIT/Apache-2.0). Its relay sockets are replaced by
//! `TunnelConn`s whose sends and receives are frames. The address a client names as the
//! peer is ignored: the host forwards everything to its own LiveKit and nowhere else.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::sync::atomic::{AtomicU16, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use async_trait::async_trait;
use bytes::Bytes;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use turn::relay::RelayAddressGenerator;
use webrtc_util::Conn;

use crate::media_host::random_alnum;
use crate::media_tunnel::{FrameSink, Routes};

const REALM: &str = "hubbub";

/// What the app hands to LiveKit's client as its only ICE server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IceConfig {
    /// `turn:<ip>:<port>?transport=udp`
    pub url: String,
    pub username: String,
    pub credential: String,
}

/// Where this node's media goes now: the current host's LiveKit. The node implements this,
/// so a host change is followed from the next allocation on.
#[async_trait]
pub trait UplinkSource: Send + Sync {
    /// A sink for frames toward the host's LiveKit, whose replies arrive in `routes`.
    async fn uplink(&self, routes: &Routes) -> Result<Arc<dyn FrameSink>>;
}

/// This machine's address for the TURN server: the source address the OS picks toward the
/// default route (a UDP connect sends nothing), IPv4 first, then IPv6, never loopback or
/// link-local. Without a default route (an isolated LAN) a private gateway guess finds the
/// attached subnet. A VPN or Tailscale address is fine when it is the default route: libwebrtc
/// enumerates every adapter, and a packet to our own address never leaves the machine.
pub fn local_media_ip() -> Option<IpAddr> {
    const PROBES: [IpAddr; 6] = [
        IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
        IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(192, 168, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)),
        IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1)),
    ];
    PROBES.iter().find_map(|probe| route_source(*probe).filter(|ip| usable_ip(*ip)))
}

fn route_source(probe: IpAddr) -> Option<IpAddr> {
    let any: IpAddr = if probe.is_ipv4() { Ipv4Addr::UNSPECIFIED.into() } else { Ipv6Addr::UNSPECIFIED.into() };
    let s = StdUdpSocket::bind((any, 0)).ok()?;
    s.connect((probe, 9)).ok()?;
    Some(s.local_addr().ok()?.ip())
}

/// An address the TURN server may bind and a client may dial: unicast, not loopback, not
/// link-local (fe80::/10 needs a scope id, 169.254/16 means no real network).
fn usable_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => !(a.is_loopback() || a.is_unspecified() || a.is_link_local() || a.is_multicast() || a.is_broadcast()),
        IpAddr::V6(a) => {
            !(a.is_loopback() || a.is_unspecified() || a.is_multicast() || (a.segments()[0] & 0xffc0) == 0xfe80)
        }
    }
}

/// A running TURN shim.
pub struct TurnShim {
    server: Arc<turn::server::Server>,
    routes: Routes,
    ice: IceConfig,
    local: SocketAddr,
}

impl Drop for TurnShim {
    fn drop(&mut self) {
        // `close` is async; it only needs to run, not to be waited for.
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let server = self.server.clone();
            rt.spawn(async move {
                let _ = server.close().await;
            });
        }
    }
}

impl TurnShim {
    /// Binds a TURN server on `ip` (an ephemeral port) with fresh random credentials.
    pub async fn start(ip: IpAddr, source: Arc<dyn UplinkSource>) -> Result<TurnShim> {
        let sock = UdpSocket::bind((ip, 0)).await.with_context(|| format!("binding the TURN shim on {ip}"))?;
        let local = sock.local_addr()?;
        let routes = Routes::default();
        let username = format!("hb{}", random_alnum(8));
        let credential = random_alnum(24);
        let cfg = turn::server::config::ServerConfig {
            conn_configs: vec![turn::server::config::ConnConfig {
                conn: Arc::new(ResetTolerant(sock)),
                relay_addr_generator: Box::new(Gen { ip, next: AtomicU16::new(0), routes: routes.clone(), source }),
            }],
            realm: REALM.to_string(),
            auth_handler: Arc::new(Auth { username: username.clone(), credential: credential.clone() }),
            channel_bind_timeout: Duration::from_secs(600),
            alloc_close_notify: None,
        };
        let server = turn::server::Server::new(cfg).await.context("starting the TURN shim")?;
        let ice = IceConfig { url: format!("turn:{local}?transport=udp"), username, credential };
        Ok(TurnShim { server: Arc::new(server), routes, ice, local })
    }

    pub fn ice(&self) -> &IceConfig {
        &self.ice
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }

    /// Allocations open now.
    pub fn allocations(&self) -> usize {
        self.routes.len()
    }

    /// The host changed: end every allocation, so none keeps sending to the old host. Clients
    /// rejoin (the app follows the host) and their new allocations go to the new one.
    pub fn repoint(&self) {
        self.routes.clear();
    }
}

struct Auth {
    username: String,
    credential: String,
}

impl turn::auth::AuthHandler for Auth {
    fn auth_handle(&self, user: &str, realm: &str, _src: SocketAddr) -> std::result::Result<Vec<u8>, turn::Error> {
        if user != self.username {
            return Err(turn::Error::Other("unknown TURN user".into()));
        }
        Ok(turn::auth::generate_auth_key(user, realm, &self.credential))
    }
}

struct Gen {
    ip: IpAddr,
    next: AtomicU16,
    routes: Routes,
    source: Arc<dyn UplinkSource>,
}

#[async_trait]
impl RelayAddressGenerator for Gen {
    fn validate(&self) -> std::result::Result<(), turn::Error> {
        Ok(())
    }

    async fn allocate_conn(
        &self,
        _use_ipv4: bool,
        _port: u16,
    ) -> std::result::Result<(Arc<dyn Conn + Send + Sync>, SocketAddr), turn::Error> {
        let uplink = self.source.uplink(&self.routes).await.map_err(|e| turn::Error::Other(format!("{e:#}")))?;
        let flow = self.next.fetch_add(1, Relaxed).wrapping_add(1);
        let rx = self.routes.open(flow);
        // The relayed address is only reported to the client; no socket listens on it.
        let relay_addr = SocketAddr::new(self.ip, 49152 + flow % 16000);
        let conn = TunnelConn { flow, uplink, routes: self.routes.clone(), rx: tokio::sync::Mutex::new(rx), peer: Mutex::new(None), relay_addr };
        Ok((Arc::new(conn), relay_addr))
    }
}

type R<T> = std::result::Result<T, webrtc_util::Error>;

/// One allocation's relay socket: sends are frames toward the host, receives are its replies.
struct TunnelConn {
    flow: u16,
    uplink: Arc<dyn FrameSink>,
    routes: Routes,
    rx: tokio::sync::Mutex<mpsc::Receiver<Bytes>>,
    /// The last address the client sent to, which labels what comes back.
    peer: Mutex<Option<SocketAddr>>,
    relay_addr: SocketAddr,
}

#[async_trait]
impl Conn for TunnelConn {
    async fn connect(&self, _addr: SocketAddr) -> R<()> {
        Ok(())
    }

    async fn recv(&self, buf: &mut [u8]) -> R<usize> {
        Ok(self.recv_from(buf).await?.0)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> R<(usize, SocketAddr)> {
        let d = self.rx.lock().await.recv().await.ok_or(webrtc_util::Error::ErrClosedListener)?;
        let n = d.len().min(buf.len());
        buf[..n].copy_from_slice(&d[..n]);
        let peer = self.peer.lock().unwrap().unwrap_or(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0));
        Ok((n, peer))
    }

    async fn send(&self, buf: &[u8]) -> R<usize> {
        self.send_to(buf, SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0)).await
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> R<usize> {
        // A cleared route means the host changed (or the shim is closing): this allocation is over.
        if !self.routes.contains(self.flow) {
            return Err(webrtc_util::Error::ErrUseClosedNetworkConn);
        }
        *self.peer.lock().unwrap() = Some(target);
        self.uplink.send_frame(self.flow, buf);
        Ok(buf.len())
    }

    fn local_addr(&self) -> R<SocketAddr> {
        Ok(self.relay_addr)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        None
    }

    async fn close(&self) -> R<()> {
        self.routes.close(self.flow);
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

/// Windows reports an ICMP port-unreachable (a peer that went away) as a receive error
/// (`ConnectionReset`, WSAECONNRESET 10054) on a UDP socket, and the TURN server's read
/// loop ends on any error: the shim would die after the first client left. Skip it.
pub struct ResetTolerant(pub UdpSocket);

#[async_trait]
impl Conn for ResetTolerant {
    async fn connect(&self, addr: SocketAddr) -> R<()> {
        Ok(self.0.connect(addr).await?)
    }

    async fn recv(&self, buf: &mut [u8]) -> R<usize> {
        Ok(self.recv_from(buf).await?.0)
    }

    async fn recv_from(&self, buf: &mut [u8]) -> R<(usize, SocketAddr)> {
        loop {
            match self.0.recv_from(buf).await {
                Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => continue,
                r => return Ok(r?),
            }
        }
    }

    async fn send(&self, buf: &[u8]) -> R<usize> {
        Ok(self.0.send(buf).await?)
    }

    async fn send_to(&self, buf: &[u8], target: SocketAddr) -> R<usize> {
        Ok(self.0.send_to(buf, target).await?)
    }

    fn local_addr(&self) -> R<SocketAddr> {
        Ok(self.0.local_addr()?)
    }

    fn remote_addr(&self) -> Option<SocketAddr> {
        None
    }

    async fn close(&self) -> R<()> {
        Ok(())
    }

    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_tunnel::{FlowLimits, FlowTable, TunnelStats};
    use tokio::time::timeout;

    const T: Duration = Duration::from_secs(5);

    async fn echo() -> SocketAddr {
        let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = s.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 70_000];
            while let Ok((n, from)) = s.recv_from(&mut buf).await {
                let _ = s.send_to(&buf[..n], from).await;
            }
        });
        addr
    }

    /// An uplink straight to a local UDP target, as on the node that hosts.
    struct Local {
        target: SocketAddr,
        stats: Arc<TunnelStats>,
        fail: bool,
    }

    #[async_trait]
    impl UplinkSource for Local {
        async fn uplink(&self, routes: &Routes) -> Result<Arc<dyn FrameSink>> {
            anyhow::ensure!(!self.fail, "no host");
            let table = FlowTable::new(self.target, Arc::new(routes.clone()), FlowLimits::default(), self.stats.clone());
            Ok(Arc::new(table))
        }
    }

    async fn shim(fail: bool) -> (TurnShim, Arc<TunnelStats>, SocketAddr) {
        let target = echo().await;
        let stats = Arc::new(TunnelStats::default());
        let source = Arc::new(Local { target, stats: stats.clone(), fail });
        (TurnShim::start("127.0.0.1".parse().unwrap(), source).await.unwrap(), stats, target)
    }

    async fn client(shim: &TurnShim, password: &str) -> turn::client::Client {
        client_as(shim, &shim.ice().username, password).await
    }

    async fn client_as(shim: &TurnShim, username: &str, password: &str) -> turn::client::Client {
        let sock = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let c = turn::client::Client::new(turn::client::ClientConfig {
            stun_serv_addr: shim.local_addr().to_string(),
            turn_serv_addr: shim.local_addr().to_string(),
            username: username.to_string(),
            password: password.to_string(),
            realm: String::new(),
            software: String::new(),
            rto_in_ms: 0,
            conn: sock,
            vnet: None,
        })
        .await
        .unwrap();
        c.listen().await.unwrap();
        c
    }

    #[tokio::test]
    async fn media_goes_up_and_comes_back_through_an_allocation() {
        let (shim, stats, target) = shim(false).await;
        assert!(shim.ice().url.starts_with("turn:127.0.0.1:") && shim.ice().url.ends_with("?transport=udp"));
        let c = client(&shim, &shim.ice().credential).await;
        let relay = timeout(T, c.allocate()).await.expect("allocation within 5 s").expect("allocated");
        relay.send_to(b"media packet", target).await.unwrap();
        let mut buf = [0u8; 64];
        let (n, from) = timeout(T, relay.recv_from(&mut buf)).await.expect("echo within 5 s").unwrap();
        assert_eq!(&buf[..n], b"media packet");
        assert_eq!(from, target, "replies are labelled with the address the client sent to");
        assert_eq!(stats.up(), (1, 12));
        assert_eq!(stats.down(), (1, 12));
        assert_eq!(shim.allocations(), 1);
    }

    #[tokio::test]
    async fn a_wrong_credential_gets_no_allocation() {
        let (shim, stats, _) = shim(false).await;
        let c = client(&shim, "not-the-password").await;
        let r = timeout(T, c.allocate()).await.expect("answered within 5 s");
        assert!(r.is_err(), "allocation with a wrong password must fail");
        assert_eq!(shim.allocations(), 0);
        assert_eq!(stats.up(), (0, 0));
    }

    #[tokio::test]
    async fn another_user_with_the_right_password_is_refused() {
        let (shim, _, _) = shim(false).await;
        let c = client_as(&shim, "someone-else", &shim.ice().credential).await;
        assert!(timeout(T, c.allocate()).await.expect("answered").is_err());
    }

    #[tokio::test]
    async fn credentials_are_random_per_shim() {
        let (a, _, _) = shim(false).await;
        let (b, _, _) = shim(false).await;
        assert_ne!(a.ice().credential, b.ice().credential);
        assert_ne!(a.ice().username, b.ice().username);
        assert_eq!(a.ice().credential.len(), 24);
    }

    #[tokio::test]
    async fn no_host_means_no_allocation() {
        let (shim, _, _) = shim(true).await;
        let c = client(&shim, &shim.ice().credential).await;
        let r = timeout(T, c.allocate()).await.expect("answered within 5 s");
        assert!(r.is_err(), "no host to forward to: the allocation is refused");
    }

    #[tokio::test]
    async fn repoint_ends_allocations_so_nothing_reaches_the_old_host() {
        let (shim, stats, target) = shim(false).await;
        let c = client(&shim, &shim.ice().credential).await;
        let relay = timeout(T, c.allocate()).await.unwrap().unwrap();
        relay.send_to(b"before", target).await.unwrap();
        let mut buf = [0u8; 64];
        timeout(T, relay.recv_from(&mut buf)).await.unwrap().unwrap();
        shim.repoint();
        assert_eq!(shim.allocations(), 0);
        let _ = relay.send_to(b"after", target).await;
        let echoed = timeout(Duration::from_millis(800), relay.recv_from(&mut buf)).await;
        assert!(echoed.is_err(), "no reply may arrive on a repointed allocation");
        assert_eq!(stats.up().0, 1, "only the packet from before the host changed went up");
        // A new allocation (the rejoining client) works again.
        let c2 = client(&shim, &shim.ice().credential).await;
        let relay2 = timeout(T, c2.allocate()).await.unwrap().unwrap();
        relay2.send_to(b"again", target).await.unwrap();
        let (n, _) = timeout(T, relay2.recv_from(&mut buf)).await.unwrap().unwrap();
        assert_eq!(&buf[..n], b"again");
        assert_eq!(stats.up().0, 2);
    }

    /// On Windows a datagram sent to a closed port makes the next receive fail with
    /// ConnectionReset; the wrapper must swallow it and deliver the next real packet.
    #[tokio::test]
    async fn reset_tolerant_socket_survives_an_icmp_port_unreachable() {
        let a = ResetTolerant(UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let a_addr = a.local_addr().unwrap();
        let closed = {
            let s = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            s.local_addr().unwrap()
        };
        a.send_to(b"into the void", closed).await.unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let other = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        other.send_to(b"real", a_addr).await.unwrap();
        let mut buf = [0u8; 16];
        let (n, _) = timeout(T, a.recv_from(&mut buf)).await.expect("not stuck").expect("no ConnectionReset error");
        assert_eq!(&buf[..n], b"real");
    }

    #[test]
    fn unusable_addresses_are_never_picked() {
        for bad in ["127.0.0.1", "0.0.0.0", "169.254.3.4", "224.0.0.1", "::1", "::", "fe80::1", "ff02::1"] {
            assert!(!usable_ip(bad.parse().unwrap()), "{bad} must not be used");
        }
        for good in ["192.168.1.5", "10.0.0.2", "100.101.102.103", "2001:db8::5", "fd00::5", "203.0.113.9"] {
            assert!(usable_ip(good.parse().unwrap()), "{good} is a valid TURN address");
        }
    }

    #[test]
    fn this_machines_media_address_is_a_usable_one() {
        if let Some(ip) = local_media_ip() {
            assert!(usable_ip(ip), "{ip}");
            // And it can really be bound: the shim needs a socket on it.
            StdUdpSocket::bind((ip, 0)).unwrap();
        }
    }
}
