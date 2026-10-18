//! Upload-bandwidth probe over an iroh connection.
use std::time::Duration;

use anyhow::{Context, Result};
use iroh::endpoint::{Connection, ReadError, RecvStream, VarInt};
use tokio::time::{timeout_at, Instant};

pub const PROBE_BYTES: u64 = 8 * 1024 * 1024;
/// A probe stops after this long even if it has not sent `PROBE_BYTES`, so a slow path is
/// loaded for a bounded time.
pub const PROBE_MAX_TIME: Duration = Duration::from_secs(2);
/// Probe data goes out only when no other stream on the connection has data waiting.
pub const PROBE_PRIORITY: i32 = i32::MIN;
/// Reset code of a probe cut short by `PROBE_MAX_TIME`; the receiver measures what arrived.
const TIME_UP: u32 = 1;

/// Megabits per second for `bytes` moved in `elapsed` (bytes * 8 / microseconds).
pub fn mbps(bytes: u64, elapsed: Duration) -> u32 {
    let micros = elapsed.as_micros().max(1) as u64;
    u32::try_from(bytes.saturating_mul(8) / micros).unwrap_or(u32::MAX)
}

/// Open a uni stream at the lowest priority and write zero bytes for `PROBE_BYTES` or
/// `PROBE_MAX_TIME`, whichever ends first. Returns the bytes written.
pub async fn send_probe(conn: &Connection) -> Result<u64> {
    send_probe_within(conn, PROBE_MAX_TIME).await
}

async fn send_probe_within(conn: &Connection, max_time: Duration) -> Result<u64> {
    let deadline = Instant::now() + max_time;
    let mut s = conn.open_uni().await.context("opening probe stream")?;
    s.set_priority(PROBE_PRIORITY).context("setting probe priority")?;
    let chunk = vec![0u8; 64 * 1024];
    let mut sent: u64 = 0;
    while sent < PROBE_BYTES {
        let n = (PROBE_BYTES - sent).min(chunk.len() as u64) as usize;
        // `write` is cancel safe: a write cut off by the deadline wrote nothing.
        match timeout_at(deadline, s.write(&chunk[..n])).await {
            Ok(written) => sent += written.context("writing probe data")? as u64,
            Err(_) => {
                // Time is up: drop whatever is still queued rather than send it late.
                let _ = s.reset(VarInt::from_u32(TIME_UP));
                return Ok(sent);
            }
        }
    }
    s.finish().context("finishing probe stream")?;
    // Wait until the receiver has taken everything so the caller can keep the connection open,
    // but no longer than the time limit.
    if timeout_at(deadline, s.stopped()).await.is_err() {
        let _ = s.reset(VarInt::from_u32(TIME_UP));
    }
    Ok(sent)
}

/// Read a probe stream to its end, or to the sender's time-limit reset, and return the
/// receiver-measured Mbps.
pub async fn recv_probe(mut r: RecvStream) -> Result<u32> {
    let start = std::time::Instant::now();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total: u64 = 0;
    loop {
        match r.read(&mut buf).await {
            Ok(Some(n)) => total += n as u64,
            Ok(None) => break,
            Err(ReadError::Reset(code)) if code == VarInt::from_u32(TIME_UP) => break,
            Err(e) => return Err(e).context("reading probe data"),
        }
    }
    Ok(mbps(total, start.elapsed()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::test_support::two_member_nets;
    
    #[test]
    fn mbps_math() {
        assert_eq!(mbps(10_000_000, Duration::from_secs(1)), 80);
    }

    #[tokio::test]
    async fn probe_measures_nonzero_in_process() {
        let (a, b) = two_member_nets().await;
        let conn = a.connect_addr(b.addr().await.unwrap(), a.ctl_alpn()).await.unwrap();
        let send = async {
            send_probe(&conn).await.unwrap();
            // Keep the connection alive until the receiver has read everything.
            conn.closed().await;
        };
        let recv = async {
            let (_who, _alpn, c) = b.accept().await.unwrap();
            let r = c.accept_uni().await.unwrap();
            let v = recv_probe(r).await.unwrap();
            c.close(0u32.into(), b"done");
            v
        };
        let (_, v) = tokio::join!(send, recv);
        assert!(v > 0, "measured {v} Mbps");
    }

    /// R25: a probe that cannot send `PROBE_BYTES` within its time limit stops at the limit,
    /// and the receiver still measures what arrived. Writing the whole probe in 50 ms would take
    /// about 140 MB/s; loopback in a test build measures 15 to 40 MB/s here.
    #[tokio::test]
    async fn probe_stops_at_its_time_limit_and_still_measures() {
        let (a, b) = two_member_nets().await;
        let conn = a.connect_addr(b.addr().await.unwrap(), a.ctl_alpn()).await.unwrap();
        let limit = Duration::from_millis(50);
        let send = async {
            let start = std::time::Instant::now();
            let sent = send_probe_within(&conn, limit).await.unwrap();
            (sent, start.elapsed())
        };
        let recv = async {
            let (_who, _alpn, c) = b.accept().await.unwrap();
            let r = c.accept_uni().await.unwrap();
            (recv_probe(r).await, c)
        };
        let ((sent, took), (measured, _c)) = tokio::join!(send, recv);
        assert!(sent < PROBE_BYTES, "the probe was not cut short: {sent} bytes in {took:?}");
        assert!(took < limit + Duration::from_millis(400), "the sender ran {took:?}");
        let v = measured.expect("a time-limited probe still gives a reading");
        assert!(v > 0, "measured {v} Mbps");
    }
}
