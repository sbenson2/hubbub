//! Control protocol: messages and length-prefixed JSON framing.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::election::RankKey;
use crate::ids::MemberId;

pub const ALPN_CTL: &[u8] = b"hubbub/ctl/0";
pub const ALPN_LK_SIGNAL: &[u8] = b"hubbub/lk-signal/0";

/// Largest frame body accepted or written, in bytes.
pub const MAX_FRAME: usize = 65_536;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerReport {
    pub member: MemberId,
    pub rtt_ms: u32,
    pub direct: bool,
    pub upload_mbps: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum CtlMsg {
    Hello { member: MemberId, can_host: bool, online_since_ms: u64 },
    Ping { nonce: u64 },
    Pong { nonce: u64 },
    Report { about: Vec<PeerReport> },
    Heartbeat { term: u64, key: RankKey },
    Announce { term: u64, key: RankKey },
    Resign { term: u64 },
    TokenRequest { room: String },
    TokenResponse { token: String },
    TokenDenied { reason: String },
    ProbeResult { mbps: u32 },
    /// A member's sealed text message, for the host to order (see `text`).
    TextSubmit {
        channel: String,
        client_id: u64,
        #[serde(with = "hex_bytes")]
        ciphertext: Vec<u8>,
    },
    /// A message the host ordered, sent to every connected member including its sender.
    TextDeliver {
        channel: String,
        term: u64,
        seq: u64,
        from: MemberId,
        client_id: u64,
        sent_ms: u64,
        #[serde(with = "hex_bytes")]
        ciphertext: Vec<u8>,
    },
}

/// Bytes as a hex string. As a JSON array of numbers, a 16 KiB ciphertext could take up to
/// 64 KiB and overflow a frame; as hex it takes 32 KiB.
mod hex_bytes {
    use serde::{de, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&hex::encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        hex::decode(String::deserialize(d)?).map_err(de::Error::custom)
    }
}

/// Write one frame: u32 big-endian length, then JSON.
pub async fn write_msg(s: &mut iroh::endpoint::SendStream, m: &CtlMsg) -> Result<()> {
    let body = serde_json::to_vec(m).context("encoding control message")?;
    if body.len() > MAX_FRAME {
        bail!("control message too large: {} bytes", body.len());
    }
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
    frame.extend_from_slice(&body);
    s.write_all(&frame).await.context("writing control frame")?;
    Ok(())
}

/// Read one frame. `Ok(None)` means the peer finished the stream cleanly
/// between frames. An oversized length is an error and the stream is closed.
pub async fn read_msg(r: &mut iroh::endpoint::RecvStream) -> Result<Option<CtlMsg>> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf).await {
        Ok(()) => {}
        Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(e).context("reading frame length"),
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME {
        let _ = r.stop(iroh::endpoint::VarInt::from_u32(1));
        bail!("control frame of {len} bytes exceeds the {MAX_FRAME} byte limit");
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await.context("reading frame body")?;
    Ok(Some(serde_json::from_slice(&body).context("decoding control message")?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn msgs_are_tagged_with_t() {
        let j = serde_json::to_string(&CtlMsg::Ping { nonce: 7 }).unwrap();
        assert_eq!(j, r#"{"t":"Ping","nonce":7}"#);
    }

    #[test]
    fn text_ciphertext_is_hex_and_the_largest_delivery_fits_a_frame() {
        let submit = CtlMsg::TextSubmit { channel: "general".into(), client_id: 1, ciphertext: vec![0xab, 0x01] };
        let j = serde_json::to_string(&submit).unwrap();
        assert_eq!(j, r#"{"t":"TextSubmit","channel":"general","client_id":1,"ciphertext":"ab01"}"#);
        assert_eq!(serde_json::from_str::<CtlMsg>(&j).unwrap(), submit);
        let largest = CtlMsg::TextDeliver {
            channel: "c".repeat(crate::text::MAX_CHANNEL_NAME),
            term: u64::MAX,
            seq: u64::MAX,
            from: MemberId([0xff; 32]),
            client_id: u64::MAX,
            sent_ms: u64::MAX,
            ciphertext: vec![0xff; crate::text::MAX_CIPHERTEXT],
        };
        let body = serde_json::to_vec(&largest).unwrap();
        assert!(body.len() <= MAX_FRAME, "{} bytes", body.len());
        assert_eq!(serde_json::from_slice::<CtlMsg>(&body).unwrap(), largest);
    }
}
