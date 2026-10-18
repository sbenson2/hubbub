//! One media host and one UPnP mapping per machine, shared by every server this device hosts.
//! A server takes a `MediaLease` while it hosts. The first lease starts the media host and
//! maps the port; releasing the last stops the host and removes the mapping. Rooms are named
//! `<cid>.<channel>`, so one server's members can never enter another server's rooms.
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use anyhow::{anyhow, Result};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout};

use crate::ids::{CommunityId, MemberId};
use crate::media_host::MediaHost;
use crate::upnp::{lan_ipv4, map_udp_on, search_gateway, unmap_udp_on, Gateway, Mapping};

const UPNP_LIFETIME_S: u32 = 3600;
const UPNP_RENEW_EVERY: Duration = Duration::from_secs(1800);
/// Budget for each call through the cached UPnP gateway, so taking the host role never waits
/// on a slow router.
const UPNP_BUDGET: Duration = Duration::from_secs(1);
/// While no UPnP gateway is cached, search for one this often.
const UPNP_SEARCH_EVERY: Duration = Duration::from_secs(300);

/// What the machine runs while at least one lease is held.
struct Run {
    host: Box<dyn MediaHost>,
    leases: usize,
    signal: Option<SocketAddr>,
    /// The UPnP mapping, with the gateway that holds it.
    mapping: Option<(Gateway, Mapping)>,
    renew: Option<JoinHandle<()>>,
}

struct Shared {
    /// Whether this machine uses UPnP at all.
    upnp: bool,
    rtc_udp: u16,
    /// The UPnP gateway found by the background search, while it keeps working.
    gateway: Mutex<Option<Gateway>>,
    warned: AtomicBool,
    /// Held while the host starts or stops, so a mint waits for a start in progress.
    run: tokio::sync::Mutex<Run>,
}

pub struct SharedMedia {
    shared: Arc<Shared>,
    search: Option<JoinHandle<()>>,
}

impl SharedMedia {
    /// `host` is the machine's one media host. With `upnp`, a background task finds the
    /// gateway so that taking the host role never waits for a search. Must run inside a
    /// tokio runtime.
    pub fn new(host: Box<dyn MediaHost>, upnp: bool, rtc_udp: u16) -> SharedMedia {
        let shared = Arc::new(Shared {
            upnp,
            rtc_udp,
            gateway: Mutex::new(None),
            warned: AtomicBool::new(false),
            run: tokio::sync::Mutex::new(Run { host, leases: 0, signal: None, mapping: None, renew: None }),
        });
        let search = upnp.then(|| tokio::spawn(gateway_loop(Arc::downgrade(&shared))));
        SharedMedia { shared, search }
    }

    /// Takes a lease for server `cid`, starting the media host and the UPnP mapping if this
    /// is the first. Fails when the host cannot start.
    pub async fn acquire(&self, cid: CommunityId) -> Result<MediaLease> {
        let sh = &self.shared;
        let mut run = sh.run.lock().await;
        let signal = match run.signal {
            Some(s) => s,
            None => {
                let s = sh.start(&mut run).await?;
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

    #[cfg(test)]
    fn set_gateway(&self, gw: Gateway) {
        *self.shared.gateway.lock().unwrap() = Some(gw);
    }
}

impl Drop for SharedMedia {
    fn drop(&mut self) {
        if let Some(t) = self.search.take() {
            t.abort();
        }
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

    /// A token for `member` to join this server's `channel`. The room is named
    /// `<cid>.<channel>`; a lease can mint for no other server's rooms.
    pub async fn mint(&self, member: &MemberId, name: &str, channel: &str) -> Result<String> {
        let run = self.shared.run.lock().await;
        if run.signal.is_none() {
            return Err(anyhow!("not host"));
        }
        run.host.mint(member, name, &format!("{}.{channel}", self.cid))
    }

    /// Gives the lease back; the last one stops the media host and removes the mapping.
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
    /// Maps the port (a hint, never fatal) and starts the host on the address that results.
    async fn start(&self, run: &mut Run) -> Result<SocketAddr> {
        let gateway = self.gateway.lock().unwrap().clone();
        let (node_ip, mapped) = advertised_ip(gateway.as_ref(), self.rtc_udp).await;
        match mapped {
            // A mapping implies a gateway.
            Ok(m) => run.mapping = gateway.map(|gw| (gw, m)),
            Err(e) => {
                if gateway.is_some() {
                    // It stopped working (or this machine moved networks): search again.
                    *self.gateway.lock().unwrap() = None;
                }
                if self.upnp && !self.warned.swap(true, Ordering::Relaxed) {
                    eprintln!("hubbub node: UPnP mapping unavailable ({e:#}); advertising {node_ip}");
                }
            }
        }
        let signal = match run.host.start(node_ip).await {
            Ok(s) => s,
            Err(e) => {
                run.unmap().await;
                return Err(e);
            }
        };
        if let Some((gw, _)) = &run.mapping {
            let (gw, port) = (gw.clone(), self.rtc_udp);
            run.renew = Some(tokio::spawn(async move {
                loop {
                    sleep(UPNP_RENEW_EVERY).await;
                    let _ = timeout(UPNP_BUDGET, map_udp_on(&gw, port, UPNP_LIFETIME_S)).await;
                }
            }));
        }
        Ok(signal)
    }

    async fn release(&self) {
        let mut run = self.run.lock().await;
        run.leases = run.leases.saturating_sub(1);
        if run.leases > 0 {
            return;
        }
        if let Some(r) = run.renew.take() {
            r.abort();
        }
        run.host.stop().await;
        run.signal = None;
        run.unmap().await;
    }
}

impl Run {
    async fn unmap(&mut self) {
        if let Some((gw, m)) = self.mapping.take() {
            let _ = timeout(UPNP_BUDGET, unmap_udp_on(&gw, &m)).await;
        }
    }
}

/// Finds the UPnP gateway in the background and caches it. While none is cached, it searches
/// again every 5 minutes. It ends when the `SharedMedia` is dropped.
async fn gateway_loop(shared: Weak<Shared>) {
    loop {
        let Some(sh) = shared.upgrade() else { return };
        if sh.gateway.lock().unwrap().is_none() {
            if let Ok(gw) = search_gateway().await {
                *sh.gateway.lock().unwrap() = Some(gw);
            }
        }
        drop(sh);
        sleep(UPNP_SEARCH_EVERY).await;
    }
}

/// This machine's private LAN address, or loopback when it has none.
fn lan_address() -> IpAddr {
    IpAddr::V4(lan_ipv4().unwrap_or(Ipv4Addr::LOCALHOST))
}

/// The address to advertise while hosting, and the UPnP mapping behind it. Only a cached
/// gateway is tried, within `UPNP_BUDGET`; otherwise the LAN address is used at once.
async fn advertised_ip(gateway: Option<&Gateway>, port: u16) -> (IpAddr, Result<Mapping>) {
    let mapped = match gateway {
        None => Err(anyhow!("no UPnP gateway found")),
        Some(gw) => match timeout(UPNP_BUDGET, map_udp_on(gw, port, UPNP_LIFETIME_S)).await {
            Ok(r) => r,
            Err(_) => Err(anyhow!("the gateway did not answer within {UPNP_BUDGET:?}")),
        },
    };
    let ip = match &mapped {
        Ok(m) => m.external_ip,
        Err(_) => lan_address(),
    };
    (ip, mapped)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;
    use std::time::Instant;

    use super::*;
    use crate::media_host::FakeHost;
    use crate::upnp::fake;

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
        let media = SharedMedia::new(host, false, 47882);
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
        let media = SharedMedia::new(host, false, 47882);
        drop(media.acquire(cid(1)).await.unwrap());
        let t0 = Instant::now();
        while stops.load(Ordering::SeqCst) == 0 {
            assert!(t0.elapsed() < Duration::from_secs(2), "the drop never released");
            sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn rooms_carry_the_server_prefix_and_a_lease_mints_only_for_its_own_server() {
        let media = SharedMedia::new(Box::new(FakeHost::new()), false, 47882);
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
    async fn upnp_is_mapped_once_and_unmapped_on_the_last_release() {
        let fake = fake::start(false).await;
        let (host, _, _) = counting();
        let media = SharedMedia::new(host, false, 47882);
        media.set_gateway(fake.gateway.clone());
        let count = |name: &str| fake.actions.lock().unwrap().iter().filter(|a| *a == name).count();
        let a = media.acquire(cid(1)).await.unwrap();
        let b = media.acquire(cid(2)).await.unwrap();
        assert_eq!(count("AddPortMapping"), 1);
        a.release().await;
        assert_eq!(count("DeletePortMapping"), 0);
        b.release().await;
        assert_eq!(count("DeletePortMapping"), 1);
        assert_eq!(count("AddPortMapping"), 1);
    }

    #[tokio::test]
    async fn a_host_that_fails_to_start_leaves_no_lease() {
        let media = SharedMedia::new(Box::new(FakeHost::failing()), false, 47882);
        assert!(media.acquire(cid(1)).await.is_err());
        assert_eq!(media.leases().await, 0);
    }

    #[tokio::test]
    async fn hosting_address_without_a_cached_gateway_is_the_lan_address_at_once() {
        let t0 = Instant::now();
        let (ip, mapped) = advertised_ip(None, 47882).await;
        assert!(t0.elapsed() < Duration::from_millis(100), "took {:?}", t0.elapsed());
        assert_eq!(ip, lan_address());
        assert!(mapped.is_err());
    }

    #[tokio::test]
    async fn hosting_address_gives_up_on_a_silent_gateway_within_the_budget() {
        let fake = fake::start(true).await;
        let t0 = Instant::now();
        let (ip, mapped) = advertised_ip(Some(&fake.gateway), 47882).await;
        let took = t0.elapsed();
        assert!(took >= UPNP_BUDGET && took < UPNP_BUDGET + Duration::from_millis(500), "took {took:?}");
        assert_eq!(ip, lan_address());
        assert!(mapped.is_err());
        assert_eq!(fake.actions.lock().unwrap().clone(), ["AddPortMapping"]);
    }

    #[tokio::test]
    async fn hosting_address_maps_through_the_cached_gateway() {
        let fake = fake::start(false).await;
        let (ip, mapped) = timeout(Duration::from_secs(5), advertised_ip(Some(&fake.gateway), 47882)).await.unwrap();
        assert_eq!(ip, fake::EXTERNAL_IP);
        assert_eq!(mapped.unwrap().external_port, 47882);
    }
}
