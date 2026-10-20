//! Dev tool: a host node (real livekit-server, loopback only) and a member node in one
//! process, so an external WebRTC client can prove call media crosses the tunnel.
//!
//!   cargo run -p hubbub-core --features test-util --example relay_check -- <out.json> [signal_port] [rtc_port]
//!
//! It writes the member's tunnel URL, its TURN ICE server and two LiveKit tokens to
//! `<out.json>`, prints tunnel counters every 2 s, and exits when `<out.json>.stop` exists.
//! `tools/relay-check/` has the Chrome and pion clients that use that file.
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use hubbub_core::community::CommunityState;
use hubbub_core::identity::Identity;
use hubbub_core::ids::MemberId;
use hubbub_core::media_host::{LiveKitHost, LkPorts, MediaHost};
use hubbub_core::net::RelayChoice;
use hubbub_core::node::{Node, NodeConfig};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = PathBuf::from(args.get(1).expect("usage: relay_check <out.json> [signal_port] [rtc_port]"));
    let signal: u16 = args.get(2).map_or(17990, |s| s.parse().unwrap());
    let rtc: u16 = args.get(3).map_or(17992, |s| s.parse().unwrap());
    let bin = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vendor/livekit/windows-amd64/livekit-server.exe");

    let (dh, dm, dl) = (tempfile::tempdir()?, tempfile::tempdir()?, tempfile::tempdir()?);
    let (ih, im) = (Identity::load_or_create(dh.path())?, Identity::load_or_create(dm.path())?);
    let state = CommunityState::for_tests("relay-check", &[(&ih, "host", true), (&im, "member", false)]);
    let file = dh.path().join("community.json");
    state.save_atomic(&file)?;

    let lk = LiveKitHost::new(bin, dl.path().to_path_buf(), LkPorts { signal, rtc_tcp: 0, rtc_udp: rtc });
    let room = "relaycheck";
    let tok_pub = lk.mint(&MemberId([1; 32]), "pub", room)?;
    let tok_sub = lk.mint(&MemberId([2; 32]), "sub", room)?;
    let cfg = |dir: &tempfile::TempDir, can_host| NodeConfig {
        data_dir: dir.path().to_path_buf(),
        community_file: file.clone(),
        can_host,
        relay: RelayChoice::Disabled,
    };
    let host = Node::start_with_addrs(cfg(&dh, true), Box::new(lk), vec![]).await?;
    let member = Node::start_with_addrs(cfg(&dm, false), Box::new(hubbub_core::media_host::NoMediaHost), vec![host.endpoint_addr().await?]).await?;
    let creds = loop {
        match member.voice_credentials("lobby").await {
            Ok(c) if c.host == host.member_id() => break c,
            _ => tokio::time::sleep(Duration::from_millis(200)).await,
        }
    };
    let ice = creds.ice.clone().expect("this machine has a usable network address");
    let info = serde_json::json!({
        "url": creds.url, "ice_url": ice.url, "ice_user": ice.username, "ice_pass": ice.credential,
        "tok_pub": tok_pub, "tok_sub": tok_sub, "signal": signal, "rtc": rtc,
        "pid": std::process::id(), "room": room,
    });
    std::fs::write(&out, serde_json::to_string_pretty(&info)?)?;
    eprintln!("relay_check ready: {} (member tunnel {}, TURN {})", out.display(), creds.url, ice.url);
    let stop = PathBuf::from(format!("{}.stop", out.display()));
    let (host, member) = (Arc::new(host), Arc::new(member));
    while !stop.exists() {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let (h, m) = (host.media_stats(), member.media_stats());
        eprintln!(
            "member wire tx={}p/{}B rx={}p/{}B | host wire rx={}p tx={}p, to livekit {}p/{}B from livekit {}p/{}B, dropped={} stream={} flows={}",
            m.wire_tx_pkts, m.wire_tx_bytes, m.wire_rx_pkts, m.wire_rx_bytes,
            h.wire_rx_pkts, h.wire_tx_pkts, h.to_livekit_pkts, h.to_livekit_bytes, h.from_livekit_pkts, h.from_livekit_bytes,
            h.dropped + m.dropped, h.via_stream + m.via_stream, h.flows_opened
        );
        for (who, node) in [("host", &host), ("member", &member)] {
            let l = node.media_links();
            for k in &l.links {
                eprintln!(
                    "  {who} link {:?} {:?} rtt={}ms cwnd={} mtu={} maxdgram={} bufspace={} lost={}/{} cong={} try_fail={}",
                    k.role, k.path, k.rtt_ms, k.cwnd, k.mtu, k.max_datagram, k.send_buffer_space,
                    k.lost_packets, k.sent_packets, k.congestion_events, l.tunnel.try_send_failed
                );
            }
        }
    }
    eprintln!("relay_check stopping");
    Ok(())
}
