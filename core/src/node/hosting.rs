//! The media host while this node is elected: the media actor that starts, stops and mints
//! in order, the UPnP mapping behind the advertised address, and the background gateway search.
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use iroh::endpoint::VarInt;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout};

use super::{Cmd, Inner, MediaCmd, MintReply, Out};
use crate::media_host::{LkPorts, MediaHost};
use crate::proto::CtlMsg;
use crate::upnp::{lan_ipv4, map_udp_on, search_gateway, unmap_udp_on, Gateway, Mapping};

const UPNP_LIFETIME_S: u32 = 3600;
const UPNP_RENEW_EVERY: Duration = Duration::from_secs(1800);
/// Budget for each call through the cached UPnP gateway, so taking the host role never waits
/// on a slow router.
const UPNP_BUDGET: Duration = Duration::from_secs(1);
/// While no UPnP gateway is cached, search for one this often.
const UPNP_SEARCH_EVERY: Duration = Duration::from_secs(300);

/// Finds the UPnP gateway in the background and caches it, so taking the host role never
/// waits for a search. While none is cached, it searches again every 5 minutes.
pub(super) async fn gateway_loop(inner: Arc<Inner>) {
    loop {
        if inner.state.lock().unwrap().gateway.is_none() {
            if let Ok(gw) = search_gateway().await {
                inner.state.lock().unwrap().gateway = Some(gw);
            }
        }
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

/// What the media actor keeps while hosting.
#[derive(Default)]
struct Hosting {
    signal: Option<SocketAddr>,
    /// The UPnP mapping, with the gateway that holds it.
    mapping: Option<(Gateway, Mapping)>,
    renew: Option<JoinHandle<()>>,
}

impl Hosting {
    async fn start(&mut self, inner: &Inner, media: &mut dyn MediaHost) -> Result<()> {
        let rtc_udp = LkPorts::default().rtc_udp;
        // Always None when UPnP is off.
        let gateway = inner.state.lock().unwrap().gateway.clone();
        // UPnP is only a hint and never fatal: without it, advertise the LAN address.
        let (node_ip, mapped) = advertised_ip(gateway.as_ref(), rtc_udp).await;
        match mapped {
            // A mapping implies a gateway.
            Ok(m) => self.mapping = gateway.map(|gw| (gw, m)),
            Err(e) => {
                if gateway.is_some() {
                    // It stopped working (or this machine moved networks): search again.
                    inner.state.lock().unwrap().gateway = None;
                }
                if inner.upnp {
                    inner.warn_upnp_once(&format!("UPnP mapping unavailable ({e:#}); advertising {node_ip}"));
                }
            }
        }
        let signal = match media.start(node_ip).await {
            Ok(s) => s,
            Err(e) => {
                self.unmap().await;
                return Err(e);
            }
        };
        self.signal = Some(signal);
        inner.state.lock().unwrap().signal = Some(signal);
        if let Some((gw, _)) = &self.mapping {
            let gw = gw.clone();
            self.renew = Some(inner.spawn(async move {
                loop {
                    sleep(UPNP_RENEW_EVERY).await;
                    let _ = timeout(UPNP_BUDGET, map_udp_on(&gw, rtc_udp, UPNP_LIFETIME_S)).await;
                }
            }));
        }
        Ok(())
    }

    async fn stop(&mut self, inner: &Inner, media: &mut dyn MediaHost) {
        if let Some(r) = self.renew.take() {
            r.abort();
        }
        media.stop().await;
        self.signal = None;
        let served = {
            let mut st = inner.state.lock().unwrap();
            st.signal = None;
            std::mem::take(&mut st.lk_served)
        };
        for c in served {
            c.close(VarInt::from_u32(0), b"host stopped");
        }
        self.unmap().await;
    }

    async fn unmap(&mut self) {
        if let Some((gw, m)) = self.mapping.take() {
            let _ = timeout(UPNP_BUDGET, unmap_udp_on(&gw, &m)).await;
        }
    }
}

/// Owns the media host and runs its commands in order, so a stop always precedes the next
/// start and a mint waits for a start in progress.
pub(super) async fn media_actor(inner: Arc<Inner>, mut media: Box<dyn MediaHost>, mut rx: mpsc::UnboundedReceiver<MediaCmd>) {
    let mut hosting = Hosting::default();
    while let Some(cmd) = rx.recv().await {
        match cmd {
            MediaCmd::Start { term } => {
                hosting.stop(&inner, media.as_mut()).await;
                if let Err(e) = hosting.start(&inner, media.as_mut()).await {
                    eprintln!("hubbub node: media host failed to start for term {term}: {e:#}");
                    let _ = inner.election.send(Cmd::StartFailed { term });
                }
            }
            MediaCmd::Stop => hosting.stop(&inner, media.as_mut()).await,
            MediaCmd::Mint { member, room, reply } => {
                let minted = match hosting.signal {
                    Some(signal) => media.mint(&member, &inner.member_name(&member), &room).map(|t| (t, signal)),
                    None => Err(anyhow!("not host")),
                };
                match reply {
                    MintReply::Local(tx) => {
                        let _ = tx.send(minted);
                    }
                    MintReply::Peer(out) => {
                        let msg = match minted {
                            Ok((token, _)) => CtlMsg::TokenResponse { token },
                            Err(e) => CtlMsg::TokenDenied { reason: format!("{e:#}") },
                        };
                        let _ = out.send(Out::Msg(msg));
                    }
                }
            }
            MediaCmd::Shutdown(done) => {
                hosting.stop(&inner, media.as_mut()).await;
                let _ = done.send(());
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;
    use crate::upnp::fake;

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
