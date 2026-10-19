//! The media actor: while this node is elected it holds a lease on the machine's shared media
//! host, and it starts, stops and mints strictly in order.
use std::sync::Arc;

use anyhow::{anyhow, Result};
use iroh::endpoint::VarInt;
use tokio::sync::mpsc;

use super::{Cmd, Inner, MediaCmd, MintReply, Out};
use crate::media_shared::{MediaLease, SharedMedia};
use crate::proto::CtlMsg;

/// Gives up the lease (the last one stops the shared host) and closes the signal
/// connections this node served.
async fn stop(inner: &Inner, lease: &mut Option<MediaLease>) {
    if let Some(l) = lease.take() {
        l.release().await;
    }
    let served = {
        let mut st = inner.state.lock().unwrap();
        st.signal = None;
        st.rtc = None;
        std::mem::take(&mut st.lk_served)
    };
    for c in served {
        c.close(VarInt::from_u32(0), b"host stopped");
    }
}

/// Mints for `member` in `channel` of this server, which must be one of its voice channels.
async fn mint(inner: &Inner, lease: &Option<MediaLease>, member: &crate::ids::MemberId, channel: &str) -> Result<(String, std::net::SocketAddr)> {
    let lease = lease.as_ref().ok_or_else(|| anyhow!("not host"))?;
    if !inner.community().channels().voice.iter().any(|c| c == channel) {
        return Err(anyhow!("{channel:?} is not a voice channel of this server"));
    }
    let token = lease.mint(member, &inner.member_name(member), channel).await?;
    Ok((token, lease.signal()))
}

/// Owns this node's lease and runs its commands in order, so a stop always precedes the next
/// start and a mint waits for a start in progress.
pub(super) async fn media_actor(inner: Arc<Inner>, media: Arc<SharedMedia>, mut rx: mpsc::UnboundedReceiver<MediaCmd>) {
    let mut lease: Option<MediaLease> = None;
    while let Some(cmd) = rx.recv().await {
        match cmd {
            MediaCmd::Start { term } => {
                stop(&inner, &mut lease).await;
                match media.acquire(inner.community().id).await {
                    Ok(l) => {
                        {
                            let mut st = inner.state.lock().unwrap();
                            st.signal = Some(l.signal());
                            st.rtc = Some(l.rtc());
                        }
                        lease = Some(l);
                    }
                    Err(e) => {
                        eprintln!("hubbub node: media host failed to start for term {term}: {e:#}");
                        let _ = inner.election.send(Cmd::StartFailed { term });
                    }
                }
            }
            MediaCmd::Stop => stop(&inner, &mut lease).await,
            MediaCmd::Mint { member, room, reply } => {
                let minted = mint(&inner, &lease, &member, &room).await;
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
                stop(&inner, &mut lease).await;
                let _ = done.send(());
                return;
            }
        }
    }
}
