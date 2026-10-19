//! Control protocol: messages and length-prefixed JSON framing.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::community::CommunityState;
use crate::election::RankKey;
use crate::ids::{CommunityId, MemberId};

/// Prefix of a community's control ALPN; the full ALPN ends in the community id in hex.
pub const CTL_PREFIX: &[u8] = b"hubbub/ctl/2/";

/// The control protocol version a node says in its Hello. 2 added `TextHave`. Receivers skip
/// messages they do not know, so a later version can add more without a new ALPN.
pub const PROTO_VERSION: u32 = 2;

/// The control ALPN of one community: `hubbub/ctl/2/<cid-hex>`. One iroh endpoint serves
/// many communities and routes each connection by this name.
pub fn ctl_alpn(cid: &CommunityId) -> Vec<u8> {
    format!("hubbub/ctl/2/{cid}").into_bytes()
}

/// The LiveKit signal-tunnel ALPN of one community: `hubbub/sig/1/<cid-hex>`.
pub fn sig_alpn(cid: &CommunityId) -> Vec<u8> {
    format!("hubbub/sig/1/{cid}").into_bytes()
}

/// The media-tunnel ALPN of one community: `hubbub/media/1/<cid-hex>`. Call media (UDP) rides
/// QUIC datagrams on it, between a member and the host that runs the community's LiveKit.
pub fn media_alpn(cid: &CommunityId) -> Vec<u8> {
    format!("hubbub/media/1/{cid}").into_bytes()
}

/// Prefix of a community's rejoin ALPN, the one route a non-member may use (see `join`).
pub const REJOIN_PREFIX: &[u8] = b"hubbub/rejoin/1/";

/// The rejoin ALPN of one community: `hubbub/rejoin/1/<cid-hex>`. A member that the others
/// have not heard of yet shows its signed entry chain here, so they let it in.
pub fn rejoin_alpn(cid: &CommunityId) -> Vec<u8> {
    format!("hubbub/rejoin/1/{cid}").into_bytes()
}

/// The ALPN of a member's join door, a fixed name: a stranger knows no community yet.
pub const JOIN_ALPN: &[u8] = b"hubbub/join/1";

/// Largest frame body accepted or written, in bytes.
pub const MAX_FRAME: usize = 65_536;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerReport {
    pub member: MemberId,
    pub rtt_ms: u32,
    pub direct: bool,
    pub upload_mbps: Option<u32>,
}

/// What a member holds of one text channel: its newest stored messages, so a host can send
/// what is missing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HaveChannel {
    pub channel: String,
    /// When the oldest of `ids` was ordered (host clock, ms), if the list is full; else 0.
    /// Nothing older is wanted: the member has seen the channel since.
    pub floor_ms: u64,
    pub ids: Vec<(MemberId, u64)>,
}

/// One member in a voice channel, with their mute and deafen state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoicePresence {
    pub member: MemberId,
    pub channel: String,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub deafened: bool,
}

/// Every control message between nodes.
///
/// Mixed versions talk to each other (friends update at different times), so changes follow
/// one rule: a field added to a message is optional (`#[serde(default)]`), and a new message
/// is a new variant that older nodes read as `Unknown` and skip. A new *required* field makes
/// older nodes fail to decode the whole message, log it as `Unknown` and silently ignore it
/// (an ignored `Heartbeat` or `Announce` splits the election with no error anywhere). Anything
/// that changes framing, or must not be ignored, gets a new ALPN (`hubbub/ctl/3/...`,
/// `hubbub/sig/2/...`, the media ALPN) instead.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum CtlMsg {
    Hello {
        member: MemberId,
        can_host: bool,
        online_since_ms: u64,
        /// `PROTO_VERSION` of the sender; 0 when absent.
        #[serde(default)]
        proto: u32,
    },
    /// The sender's community state without the secret, sent after `Hello` and on every
    /// change. The receiver merges it; see `Node::apply_state`.
    StateSync { state: CommunityState },
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
    /// Sent first on every session: what this node holds of each text channel, and when it
    /// first ran this community (`since_ms`). A host sends back only the deliveries it
    /// ordered since then that the node lacks, and starts live deliveries on this session.
    TextHave { since_ms: u64, have: Vec<HaveChannel> },
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
    /// The sender's own voice-channel state, sent to its direct peers on every change and on
    /// every new session while it is in a call. The receiver takes the member from the session.
    /// `channel: None` means not in a call.
    VoiceState {
        channel: Option<String>,
        #[serde(default)]
        muted: bool,
        #[serde(default)]
        deafened: bool,
    },
    /// Who is in which voice channel, as the host sees it (its own state plus every direct
    /// peer's). Sent by the host to all peers on every change, to each new session and when it
    /// becomes host. A member accepts it only from the member it sees as host at `term`.
    VoiceRoster { term: u64, entries: Vec<VoicePresence> },
    /// Never sent: what `read_msg` returns for a frame it cannot decode (a message from a newer
    /// build). The session skips it.
    #[serde(skip)]
    Unknown,
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
    write_json(s, m).await
}

/// Read one frame. A frame that is valid JSON but no message this build knows comes back as
/// `CtlMsg::Unknown`, so the session goes on. `Ok(None)` means the peer finished the stream cleanly
/// between frames. An oversized length is an error and the stream is closed.
pub async fn read_msg(r: &mut iroh::endpoint::RecvStream) -> Result<Option<CtlMsg>> {
    let Some(value) = read_json::<serde_json::Value>(r).await? else { return Ok(None) };
    Ok(Some(decode_msg(value)))
}

/// A frame's JSON as a message; `Unknown` if this build cannot read it.
fn decode_msg(value: serde_json::Value) -> CtlMsg {
    serde_json::from_value(value).unwrap_or_else(|e| {
        eprintln!("hubbub: skipping a control message it cannot read: {e}");
        CtlMsg::Unknown
    })
}

/// `write_msg` for any message type (the join protocol has its own).
pub async fn write_json<T: Serialize>(s: &mut iroh::endpoint::SendStream, m: &T) -> Result<()> {
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

/// `read_msg` for any message type.
pub async fn read_json<T: serde::de::DeserializeOwned>(r: &mut iroh::endpoint::RecvStream) -> Result<Option<T>> {
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
    fn alpns_name_the_community() {
        let cid: CommunityId = "000102030405060708090a0b0c0d0e0f".parse().unwrap();
        assert_eq!(ctl_alpn(&cid), b"hubbub/ctl/2/000102030405060708090a0b0c0d0e0f");
        assert_eq!(sig_alpn(&cid), b"hubbub/sig/1/000102030405060708090a0b0c0d0e0f");
        assert_eq!(media_alpn(&cid), b"hubbub/media/1/000102030405060708090a0b0c0d0e0f");
        assert!(ctl_alpn(&cid).starts_with(CTL_PREFIX));
    }

    #[test]
    fn voice_messages_round_trip_and_older_fields_default() {
        let state = CtlMsg::VoiceState { channel: Some("lobby".into()), muted: true, deafened: false };
        let j = serde_json::to_string(&state).unwrap();
        assert_eq!(j, r#"{"t":"VoiceState","channel":"lobby","muted":true,"deafened":false}"#);
        assert_eq!(serde_json::from_str::<CtlMsg>(&j).unwrap(), state);
        let bare: CtlMsg = serde_json::from_str(r#"{"t":"VoiceState","channel":null}"#).unwrap();
        assert_eq!(bare, CtlMsg::VoiceState { channel: None, muted: false, deafened: false });
        let roster = CtlMsg::VoiceRoster {
            term: 3,
            entries: vec![VoicePresence { member: MemberId([7; 32]), channel: "lobby".into(), muted: false, deafened: true }],
        };
        let j = serde_json::to_string(&roster).unwrap();
        assert_eq!(serde_json::from_str::<CtlMsg>(&j).unwrap(), roster);
    }

    #[test]
    fn a_message_from_a_newer_build_is_unknown() {
        let future: serde_json::Value = serde_json::from_str(r#"{"t":"FromTheFuture","x":1}"#).unwrap();
        assert_eq!(decode_msg(future), CtlMsg::Unknown);
        let known: serde_json::Value = serde_json::from_str(r#"{"t":"Ping","nonce":1}"#).unwrap();
        assert_eq!(decode_msg(known), CtlMsg::Ping { nonce: 1 });
    }

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
