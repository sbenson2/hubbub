//! The node's side of the media tunnel: the TURN shim that call media enters, and the uplink
//! that carries it to whoever hosts now (the local LiveKit when this node hosts, else the
//! host's media connection).
use std::net::IpAddr;
use std::sync::{Arc, Mutex, Weak};

use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio::task::JoinHandle;

use super::Inner;
use crate::ids::MemberId;
use crate::media_shim::{local_media_ip, IceConfig, TurnShim, UplinkSource};
use crate::media_tunnel::{pump, FlowLimits, FlowTable, FrameSink, IrohSender, Routes, TunnelStats};

/// The shim, and the address it listens on.
pub(super) struct ShimSlot {
    ip: IpAddr,
    shim: Arc<TurnShim>,
}

/// What the uplink currently points at.
enum Cached {
    Nothing,
    /// This node hosts: frames go to the local LiveKit.
    Local { rtc: std::net::SocketAddr, table: Arc<FlowTable> },
    /// Another member hosts: frames go over a media connection to it.
    Remote { host: MemberId, conn: iroh::endpoint::Connection, sender: Arc<IrohSender>, pump: JoinHandle<()> },
}

impl Cached {
    fn close(&mut self) {
        if let Cached::Remote { conn, pump, .. } = std::mem::replace(self, Cached::Nothing) {
            pump.abort();
            conn.close(iroh::endpoint::VarInt::from_u32(0), b"repoint");
        }
    }
}

/// Resolves the uplink for each new allocation from the current host, so a host change
/// applies from the next allocation (and `repoint` ends the old ones).
pub(super) struct NodeUplink {
    inner: Weak<Inner>,
    cached: Mutex<Cached>,
    /// Held from the cache check through the dial, so allocations that arrive together on a
    /// cold member share one connection instead of replacing each other's.
    dial: tokio::sync::Mutex<()>,
    stats: Arc<TunnelStats>,
}

impl Drop for NodeUplink {
    fn drop(&mut self) {
        self.cached.lock().unwrap().close();
    }
}

#[async_trait]
impl UplinkSource for NodeUplink {
    async fn uplink(&self, routes: &Routes) -> Result<Arc<dyn FrameSink>> {
        let inner = self.inner.upgrade().context("node stopped")?;
        let (host, rtc) = {
            let st = inner.state.lock().unwrap();
            (st.host.host, st.rtc)
        };
        let host = host.context("no host is elected")?;
        if host == inner.me {
            let rtc = rtc.context("the media host is not running")?;
            let mut cached = self.cached.lock().unwrap();
            if let Cached::Local { rtc: r, table } = &*cached {
                if *r == rtc {
                    return Ok(table.clone());
                }
            }
            cached.close();
            let table = Arc::new(FlowTable::new(rtc, Arc::new(routes.clone()), FlowLimits::default(), self.stats.clone()));
            *cached = Cached::Local { rtc, table: table.clone() };
            return Ok(table);
        }
        if let Some(sender) = self.live_remote(host) {
            return Ok(sender);
        }
        let _dialing = self.dial.lock().await;
        // Another allocation may have dialed while this one waited.
        if let Some(sender) = self.live_remote(host) {
            return Ok(sender);
        }
        // The host may have changed while this allocation waited for the lock: do not dial the
        // old one (the client asks again and gets the new host).
        if inner.state.lock().unwrap().host.host != Some(host) {
            anyhow::bail!("the host changed while this allocation waited to dial");
        }
        let conn = inner.dial_within(host, inner.net.media_alpn(), super::MEDIA_DIAL_TIMEOUT).await?;
        let sender = Arc::new(IrohSender::new(conn.clone(), self.stats.clone()));
        let down = routes.clone();
        let reader = tokio::spawn(pump(conn.clone(), self.stats.clone(), move |flow, payload| down.send_frame(flow, &payload)));
        let mut cached = self.cached.lock().unwrap();
        // Nothing live toward `host` is cached here (checked under the dial lock), so this
        // only retires a connection to an old host or a dead one.
        cached.close();
        *cached = Cached::Remote { host, conn, sender: sender.clone(), pump: reader };
        Ok(sender)
    }

    fn repoint(&self) {
        self.cached.lock().unwrap().close();
    }
}

impl NodeUplink {
    /// The cached connection to `host`, if it is still open.
    fn live_remote(&self, host: MemberId) -> Option<Arc<IrohSender>> {
        match &*self.cached.lock().unwrap() {
            Cached::Remote { host: h, conn, sender, .. } if *h == host && conn.close_reason().is_none() => Some(sender.clone()),
            _ => None,
        }
    }
}

impl Inner {
    /// The ICE server for the app's LiveKit client: this node's TURN shim, started on first
    /// use and restarted if the machine's address changed. `None` when the machine has no
    /// usable address or the shim cannot start; the app then refuses to join, because media
    /// has no other way to the host.
    pub(super) async fn ice_config(self: &Arc<Self>) -> Option<IceConfig> {
        let _gate = self.shim_gate.lock().await;
        let ip = local_media_ip()?;
        if let Some(slot) = &*self.shim.lock().unwrap() {
            if slot.ip == ip {
                return Some(slot.shim.ice().clone());
            }
        }
        let source = Arc::new(NodeUplink {
            inner: Arc::downgrade(self),
            cached: Mutex::new(Cached::Nothing),
            dial: tokio::sync::Mutex::new(()),
            stats: self.media_stats.clone(),
        });
        match TurnShim::start(ip, source).await {
            Ok(shim) => {
                let ice = shim.ice().clone();
                *self.shim.lock().unwrap() = Some(ShimSlot { ip, shim: Arc::new(shim) });
                Some(ice)
            }
            Err(e) => {
                eprintln!("hubbub node: media shim did not start on {ip}: {e:#}");
                None
            }
        }
    }

    /// The host changed: end the calls' allocations so none keeps sending to the old host.
    pub(super) fn repoint_media(&self) {
        if let Some(slot) = &*self.shim.lock().unwrap() {
            slot.shim.repoint();
        }
    }
}
