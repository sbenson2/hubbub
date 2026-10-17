//! UPnP port mapping for the host's listening port.
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use anyhow::{Context, Result};
use igd_next::{PortMappingProtocol, SearchOptions};

/// A UPnP gateway found on the LAN, kept so later mappings need no new search.
pub type Gateway = igd_next::aio::Gateway<igd_next::aio::tokio::Tokio>;

/// A UPnP mapping. Only a hint: peers' observed direct connections decide reachability.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mapping {
    pub external_ip: IpAddr,
    pub external_port: u16,
    pub local_port: u16,
}

/// Searches the LAN for a UPnP gateway: an SSDP search of up to 3 s.
pub async fn search_gateway() -> Result<Gateway> {
    let mut opts = SearchOptions::default();
    opts.timeout = Some(Duration::from_secs(3));
    igd_next::aio::tokio::search_gateway(opts).await.context("searching for a UPnP gateway")
}

/// Maps `local_port` to the same external UDP port on `gw` for `lifetime_s` seconds.
pub async fn map_udp_on(gw: &Gateway, local_port: u16, lifetime_s: u32) -> Result<Mapping> {
    // Find the local address that routes to the gateway; connecting a UDP socket sends nothing.
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").context("binding probe socket")?;
    probe.connect(gw.addr).context("routing to gateway")?;
    let local_ip = probe.local_addr().context("reading local address")?.ip();
    gw.add_port(PortMappingProtocol::UDP, local_port, SocketAddr::new(local_ip, local_port), lifetime_s, "hubbub")
        .await
        .context("adding UDP port mapping")?;
    let external_ip = gw.get_external_ip().await.context("reading external IP")?;
    Ok(Mapping { external_ip, external_port: local_port, local_port })
}

pub async fn unmap_udp_on(gw: &Gateway, m: &Mapping) -> Result<()> {
    gw.remove_port(PortMappingProtocol::UDP, m.external_port).await.context("removing UDP port mapping")?;
    Ok(())
}

/// Searches for the gateway, then maps `local_port` on it (see `map_udp_on`).
pub async fn map_udp(local_port: u16, lifetime_s: u32) -> Result<Mapping> {
    map_udp_on(&search_gateway().await?, local_port, lifetime_s).await
}

/// Searches for the gateway, then removes `m` from it.
pub async fn unmap_udp(m: &Mapping) -> Result<()> {
    unmap_udp_on(&search_gateway().await?, m).await
}

/// This machine's private LAN IPv4: the source address the OS picks for the default route.
/// Connecting a UDP socket only looks up the route; nothing is sent.
pub fn lan_ipv4() -> Option<Ipv4Addr> {
    let s = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    s.connect((Ipv4Addr::new(192, 0, 2, 1), 9)).ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if ip.is_private() => Some(ip),
        _ => None,
    }
}

/// A UPnP gateway on 127.0.0.1 for tests. It answers AddPortMapping, GetExternalIPAddress
/// and DeletePortMapping and records each action; with `hang` it reads requests and never answers.
#[cfg(test)]
pub(crate) mod fake {
    use std::collections::HashMap;
    use std::net::{IpAddr, Ipv4Addr};
    use std::sync::{Arc, Mutex};

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    use super::Gateway;

    pub(crate) const EXTERNAL_IP: IpAddr = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 7));

    pub(crate) struct FakeGateway {
        pub(crate) gateway: Gateway,
        pub(crate) actions: Arc<Mutex<Vec<String>>>,
    }

    pub(crate) async fn start(hang: bool) -> FakeGateway {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let actions = Arc::new(Mutex::new(Vec::new()));
        let seen = actions.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(answer(stream, seen.clone(), hang));
            }
        });
        let args = |names: &[&str]| names.iter().map(|n| n.to_string()).collect::<Vec<_>>();
        let control_schema = HashMap::from([
            (
                "AddPortMapping".to_string(),
                args(&[
                    "NewRemoteHost",
                    "NewExternalPort",
                    "NewProtocol",
                    "NewInternalPort",
                    "NewInternalClient",
                    "NewEnabled",
                    "NewPortMappingDescription",
                    "NewLeaseDuration",
                ]),
            ),
            ("DeletePortMapping".to_string(), args(&["NewRemoteHost", "NewExternalPort", "NewProtocol"])),
        ]);
        let gateway = Gateway {
            addr,
            root_url: "/root.xml".to_string(),
            control_url: "/ctl".to_string(),
            control_schema_url: "/scpd.xml".to_string(),
            control_schema,
            service_type: "urn:schemas-upnp-org:service:WANIPConnection:1".to_string(),
            provider: igd_next::aio::tokio::Tokio,
        };
        FakeGateway { gateway, actions }
    }

    async fn answer(mut stream: TcpStream, seen: Arc<Mutex<Vec<String>>>, hang: bool) {
        let mut req = Vec::new();
        let mut buf = [0u8; 4096];
        let body_at = loop {
            let Ok(n @ 1..) = stream.read(&mut buf).await else { return };
            req.extend_from_slice(&buf[..n]);
            if let Some(i) = req.windows(4).position(|w| w == b"\r\n\r\n") {
                break i + 4;
            }
        };
        let head = String::from_utf8_lossy(&req[..body_at]).to_ascii_lowercase();
        let header = |name: &str| {
            head.lines().find_map(|l| l.strip_prefix(name).map(|v| v.trim().trim_matches('"').to_string()))
        };
        let len: usize = header("content-length:").and_then(|v| v.parse().ok()).unwrap_or(0);
        while req.len() < body_at + len {
            let Ok(n @ 1..) = stream.read(&mut buf).await else { return };
            req.extend_from_slice(&buf[..n]);
        }
        let soap_action = header("soapaction:").unwrap_or_default();
        let action = ["AddPortMapping", "GetExternalIPAddress", "DeletePortMapping"]
            .into_iter()
            .find(|a| soap_action.ends_with(&format!("#{}", a.to_ascii_lowercase())))
            .unwrap_or("Unknown");
        seen.lock().unwrap().push(action.to_string());
        if hang {
            std::future::pending::<()>().await;
        }
        let inner = if action == "GetExternalIPAddress" {
            format!("<NewExternalIPAddress>{EXTERNAL_IP}</NewExternalIPAddress>")
        } else {
            String::new()
        };
        let body = format!(
            "<?xml version=\"1.0\"?><Envelope><Body><{action}Response>{inner}</{action}Response></Body></Envelope>"
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(resp.as_bytes()).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "needs a UPnP router"]
    async fn upnp_maps_and_unmaps() {
        let m = map_udp(47882, 120).await.unwrap();
        println!("upnp mapped external {}:{}", m.external_ip, m.external_port);
        let unmapped = unmap_udp(&m).await;
        assert_eq!(m.local_port, 47882);
        unmapped.unwrap();
    }

    #[tokio::test]
    async fn maps_and_unmaps_on_a_given_gateway() {
        let fake = fake::start(false).await;
        let m = tokio::time::timeout(Duration::from_secs(5), map_udp_on(&fake.gateway, 47882, 120))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(m, Mapping { external_ip: fake::EXTERNAL_IP, external_port: 47882, local_port: 47882 });
        tokio::time::timeout(Duration::from_secs(5), unmap_udp_on(&fake.gateway, &m)).await.unwrap().unwrap();
        let actions = fake.actions.lock().unwrap().clone();
        assert_eq!(actions, ["AddPortMapping", "GetExternalIPAddress", "DeletePortMapping"]);
    }
}
