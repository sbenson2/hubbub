//! One media host per machine, shared by every server this device hosts.
//! A server takes a `MediaLease` while it hosts. The first lease starts the media host;
//! releasing the last stops it. Rooms are named `<cid>.<channel>`, so one server's members
//! can never enter another server's rooms.
//!
//! LiveKit is started bound to loopback only (see `media_host::render_config`): it opens no
//! port on a real network interface, so there is no firewall prompt and nothing to map on the
//! router. Remote members' media reaches it through the iroh connection (`media_tunnel`).
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;

use anyhow::{anyhow, Result};

use crate::ids::{CommunityId, MemberId};
use crate::media_host::MediaHost;

/// What the machine runs while at least one lease is held.
struct Run {
    host: Box<dyn MediaHost>,
    leases: usize,
    signal: Option<SocketAddr>,
}

struct Shared {
    rtc: SocketAddr,
    /// Held while the host starts or stops, so a mint waits for a start in progress.
    run: tokio::sync::Mutex<Run>,
}

pub struct SharedMedia {
    shared: Arc<Shared>,
}

impl SharedMedia {
    /// `host` is the machine's one media host.
    pub fn new(host: Box<dyn MediaHost>) -> SharedMedia {
        let rtc = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), host.rtc_port());
        let shared = Arc::new(Shared { rtc, run: tokio::sync::Mutex::new(Run { host, leases: 0, signal: None }) });
        SharedMedia { shared }
    }

    /// Takes a lease for server `cid`, starting the media host if this is the first.
    /// Fails when the host cannot start.
    pub async fn acquire(&self, cid: CommunityId) -> Result<MediaLease> {
        let sh = &self.shared;
        let mut run = sh.run.lock().await;
        let signal = match run.signal {
            Some(s) => s,
            None => {
                // LiveKit binds loopback only; the address is not advertised to anyone.
                let s = run.host.start(IpAddr::V4(Ipv4Addr::LOCALHOST)).await?;
                run.signal = Some(s);
                s
            }
        };
        run.leases += 1;
        Ok(MediaLease { shared: sh.clone(), cid, signal, released: false })
    }

    /// Leases currently held (tests).
    #[cfg(test)]
    async fn leases(&self) -> usize {
        self.shared.run.lock().await.leases
    }
}

/// A server's claim on the shared media host. Release it with `release`; dropping it
/// releases in the background.
pub struct MediaLease {
    shared: Arc<Shared>,
    cid: CommunityId,
    signal: SocketAddr,
    released: bool,
}

impl MediaLease {
    /// The media host's signal address.
    pub fn signal(&self) -> SocketAddr {
        self.signal
    }

    /// The media host's UDP address, on loopback: where the media tunnel forwards to.
    pub fn rtc(&self) -> SocketAddr {
        self.shared.rtc
    }

    /// A token for `member` to join this server's `channel`. The room is named
    /// `<cid>.<channel>`; a lease can mint for no other server's rooms.
    pub async fn mint(&self, member: &MemberId, name: &str, channel: &str) -> Result<String> {
        let run = self.shared.run.lock().await;
        if run.signal.is_none() {
            return Err(anyhow!("not host"));
        }
        run.host.mint(member, name, &format!("{}.{channel}", self.cid))
    }

    /// Gives the lease back; the last one stops the media host.
    pub async fn release(mut self) {
        self.released = true;
        self.shared.release().await;
    }
}

impl Drop for MediaLease {
    fn drop(&mut self) {
        if !self.released {
            if let Ok(rt) = tokio::runtime::Handle::try_current() {
                let shared = self.shared.clone();
                rt.spawn(async move { shared.release().await });
            }
        }
    }
}

impl Shared {
    async fn release(&self) {
        let mut run = self.run.lock().await;
        run.leases = run.leases.saturating_sub(1);
        if run.leases > 0 {
            return;
        }
        run.host.stop().await;
        run.signal = None;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::time::sleep;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::media_host::FakeHost;

    /// A FakeHost that counts its starts and stops.
    struct Counting {
        inner: FakeHost,
        starts: Arc<AtomicUsize>,
        stops: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl MediaHost for Counting {
        async fn start(&mut self, ip: IpAddr) -> Result<SocketAddr> {
            self.starts.fetch_add(1, Ordering::SeqCst);
            self.inner.start(ip).await
        }
        async fn stop(&mut self) {
            self.stops.fetch_add(1, Ordering::SeqCst);
            self.inner.stop().await
        }
        fn mint(&self, member: &MemberId, name: &str, room: &str) -> Result<String> {
            self.inner.mint(member, name, room)
        }
    }

    fn counting() -> (Box<dyn MediaHost>, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let (starts, stops) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        (Box::new(Counting { inner: FakeHost::new(), starts: starts.clone(), stops: stops.clone() }), starts, stops)
    }

    fn cid(n: u8) -> CommunityId {
        CommunityId([n; 16])
    }

    #[tokio::test]
    async fn two_servers_share_one_host_start_and_the_last_release_stops_it() {
        let (host, starts, stops) = counting();
        let media = SharedMedia::new(host);
        let a = media.acquire(cid(1)).await.unwrap();
        let b = media.acquire(cid(2)).await.unwrap();
        assert_eq!(a.signal(), b.signal());
        assert_eq!(starts.load(Ordering::SeqCst), 1, "one LiveKit for two servers");
        a.release().await;
        assert_eq!(stops.load(Ordering::SeqCst), 0, "still in use by the other server");
        assert!(b.mint(&MemberId([9; 32]), "x", "lobby").await.is_ok());
        b.release().await;
        assert_eq!(stops.load(Ordering::SeqCst), 1);
        assert_eq!(media.leases().await, 0);
        // A later lease starts it afresh.
        let c = media.acquire(cid(1)).await.unwrap();
        assert_eq!(starts.load(Ordering::SeqCst), 2);
        c.release().await;
    }

    #[tokio::test]
    async fn dropping_the_last_lease_stops_the_host() {
        let (host, _, stops) = counting();
        let media = SharedMedia::new(host);
        drop(media.acquire(cid(1)).await.unwrap());
        let t0 = Instant::now();
        while stops.load(Ordering::SeqCst) == 0 {
            assert!(t0.elapsed() < Duration::from_secs(2), "the drop never released");
            sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn rooms_carry_the_server_prefix_and_a_lease_mints_only_for_its_own_server() {
        let media = SharedMedia::new(Box::new(FakeHost::new()));
        let (a, b) = (media.acquire(cid(1)).await.unwrap(), media.acquire(cid(2)).await.unwrap());
        let m = MemberId([7; 32]);
        assert_eq!(a.mint(&m, "m", "lobby").await.unwrap(), format!("fake:{m}:{}.lobby", cid(1)));
        assert_eq!(b.mint(&m, "m", "lobby").await.unwrap(), format!("fake:{m}:{}.lobby", cid(2)));
        // Naming the other server's room only nests it under this server's prefix.
        let asked = format!("{}.lobby", cid(2));
        let room = a.mint(&m, "m", &asked).await.unwrap();
        assert_eq!(room, format!("fake:{m}:{}.{asked}", cid(1)));
        assert_ne!(room, b.mint(&m, "m", "lobby").await.unwrap());
    }

    #[tokio::test]
    async fn a_host_that_fails_to_start_leaves_no_lease() {
        let media = SharedMedia::new(Box::new(FakeHost::failing()));
        assert!(media.acquire(cid(1)).await.is_err());
        assert_eq!(media.leases().await, 0);
    }
}
