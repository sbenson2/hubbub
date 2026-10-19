//! Call media through the iroh tunnel, against the real vendored livekit-server.
//! LiveKit ports here avoid 7880-7882, which a running Hubbub may hold.
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, UdpSocket};
use std::path::PathBuf;

use hubbub_core::media_host::{LiveKitHost, LkPorts, MediaHost};

const SIGNAL: u16 = 17980;
const RTC_UDP: u16 = 17982;

/// The vendored livekit-server for this OS, if there is one.
fn livekit_bin() -> Option<PathBuf> {
    let vendor = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vendor/livekit");
    let bin = if cfg!(windows) {
        vendor.join("windows-amd64/livekit-server.exe")
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        vendor.join("linux-amd64/livekit-server")
    } else {
        return None;
    };
    bin.exists().then_some(bin)
}

/// The source address the OS picks for the default route (sends nothing).
fn lan_ip() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    s.connect((Ipv4Addr::new(192, 0, 2, 1), 9)).ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

#[tokio::test]
async fn livekit_listens_on_loopback_and_nothing_on_a_real_interface() {
    let Some(bin) = livekit_bin() else { return };
    let Some(lan) = lan_ip() else { return };
    let work = tempfile::tempdir().unwrap();
    let ports = LkPorts { signal: SIGNAL, rtc_tcp: 0, rtc_udp: RTC_UDP };
    let mut host = LiveKitHost::new(bin, work.path().to_path_buf(), ports);
    let signal = host.start(IpAddr::V4(Ipv4Addr::LOCALHOST)).await.expect("livekit starts");
    assert_eq!(signal, SocketAddr::from(([127, 0, 0, 1], SIGNAL)));
    assert_eq!(host.rtc_port(), RTC_UDP);

    // Loopback is taken (by LiveKit), so the media port really is open there ...
    assert!(UdpSocket::bind((Ipv4Addr::LOCALHOST, RTC_UDP)).is_err(), "LiveKit must hold 127.0.0.1:{RTC_UDP}/udp");
    // ... while the same ports on the LAN address are free: a socket of LiveKit's on any real
    // interface (or the wildcard) would make these binds fail, and would raise the firewall prompt.
    UdpSocket::bind((lan, RTC_UDP)).unwrap_or_else(|e| panic!("LiveKit holds UDP {RTC_UDP} on {lan}: {e}"));
    TcpListener::bind((lan, SIGNAL)).unwrap_or_else(|e| panic!("LiveKit holds TCP {SIGNAL} on {lan}: {e}"));
    // No ICE-TCP listener (livekit's default would bind 7881 on every interface).
    host.stop().await;
}
