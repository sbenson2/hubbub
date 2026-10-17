//! Pipes LiveKit's localhost-only signal port between members over iroh bi-streams.
use std::future::Future;
use std::net::SocketAddr;

use iroh::endpoint::{Connection, RecvStream, SendStream};
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};

/// Accept local TCP connections and pipe each over a fresh stream from `open`.
/// `open` runs per connection, so a host change applies from the next connection.
pub async fn serve_local<F, Fut>(listener: TcpListener, open: F) -> anyhow::Result<()>
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = anyhow::Result<(SendStream, RecvStream)>> + Send,
{
    let open = std::sync::Arc::new(open);
    loop {
        let (tcp, _) = listener.accept().await?;
        let open = open.clone();
        tokio::spawn(async move {
            match open().await {
                Ok((send, recv)) => {
                    let _ = pipe(tcp, send, recv).await;
                }
                Err(e) => eprintln!("signal tunnel: opening stream to host failed: {e:#}"),
            }
        });
    }
}

/// Pipe every bi stream the peer opens on `conn` into a TCP connection to `target`.
/// Returns `Ok(())` when the iroh connection closes.
pub async fn serve_host(conn: Connection, target: SocketAddr) -> anyhow::Result<()> {
    loop {
        let (mut send, recv) = match conn.accept_bi().await {
            Ok(s) => s,
            Err(iroh::endpoint::ConnectionError::ApplicationClosed(_))
            | Err(iroh::endpoint::ConnectionError::ConnectionClosed(_))
            | Err(iroh::endpoint::ConnectionError::LocallyClosed)
            | Err(iroh::endpoint::ConnectionError::TimedOut) => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        tokio::spawn(async move {
            match TcpStream::connect(target).await {
                Ok(tcp) => {
                    let _ = pipe(tcp, send, recv).await;
                }
                Err(e) => {
                    eprintln!("signal tunnel: connecting to {target} failed: {e}");
                    // Finish so the client side reads EOF.
                    let _ = send.finish();
                }
            }
        });
    }
}

/// Copy both ways until each direction hits EOF, finishing the write half after its EOF.
async fn pipe(tcp: TcpStream, mut send: SendStream, mut recv: RecvStream) -> anyhow::Result<()> {
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    tokio::try_join!(
        async {
            tokio::io::copy(&mut tcp_r, &mut send).await?;
            send.finish()?;
            anyhow::Ok(())
        },
        async {
            tokio::io::copy(&mut recv, &mut tcp_w).await?;
            tcp_w.shutdown().await?;
            anyhow::Ok(())
        }
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio::time::timeout;

    use super::*;
    use crate::media_host::{FakeHost, MediaHost};
    use crate::net::test_support::two_member_nets;
    use crate::proto::ALPN_LK_SIGNAL;

    const T: Duration = Duration::from_secs(1);

    /// Start `serve_host` on b toward `target`, and a local port on a that dials b.
    async fn tunnel_to(target: SocketAddr) -> SocketAddr {
        let (a, b) = two_member_nets().await;
        let b_addr = b.addr().await.unwrap();
        tokio::spawn(async move {
            while let Some((_, alpn, conn)) = b.accept().await {
                if alpn == ALPN_LK_SIGNAL {
                    tokio::spawn(serve_host(conn, target));
                }
            }
        });
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let local = listener.local_addr().unwrap();
        let a = std::sync::Arc::new(a);
        tokio::spawn(async move {
            let _ = serve_local(listener, move || {
                let (a, b_addr) = (a.clone(), b_addr.clone());
                async move {
                    let conn = a.connect_addr(b_addr, ALPN_LK_SIGNAL).await?;
                    Ok(conn.open_bi().await?)
                }
            })
            .await;
        });
        local
    }

    #[tokio::test]
    async fn tunnel_round_trips_bytes() {
        let mut host = FakeHost::new();
        let echo = host.start("127.0.0.1".parse().unwrap()).await.unwrap();
        let local = tunnel_to(echo).await;
        let mut c = TcpStream::connect(local).await.unwrap();
        c.write_all(b"hello").await.unwrap();
        let mut buf = [0u8; 5];
        timeout(T, c.read_exact(&mut buf)).await.expect("echo within 1 s").unwrap();
        assert_eq!(&buf, b"hello");
    }

    #[tokio::test]
    async fn tunnel_reports_close_when_target_down() {
        let closed = {
            let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
            l.local_addr().unwrap()
        };
        let local = tunnel_to(closed).await;
        let mut c = TcpStream::connect(local).await.unwrap();
        // iroh only surfaces the stream to the peer once the opener writes.
        c.write_all(b"x").await.unwrap();
        let mut buf = [0u8; 8];
        let n = timeout(T, c.read(&mut buf)).await.expect("EOF within 1 s").unwrap_or(0);
        assert_eq!(n, 0);
    }
}
