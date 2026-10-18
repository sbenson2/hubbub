//! The `hubbub://join/<code>` invite link. The code is a fixed binary layout signed by the
//! inviter, so any member can check an invite it never saw against its own community state.
use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, ensure, Result};
use iroh::Signature;

use crate::b64;
use crate::community::CommunityState;
use crate::identity::Identity;
use crate::ids::{CommunityId, InviteId, MemberId};

const VERSION: u8 = 1;
const PREFIX: &str = "hubbub://join/";
const TAG: &[u8] = b"hubbub invite v1";
/// The server name in a link, in UTF-8 bytes.
pub const MAX_INVITE_NAME_BYTES: usize = 24;
pub const MAX_DOORS: usize = 3;

/// Why a member refuses an invite.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Deny {
    Expired,
    Revoked,
    UsedUp,
    /// The inviter is not a verified member here (or the link is for another community).
    UnknownInviter,
    BadSignature,
}

impl fmt::Display for Deny {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Deny::Expired => "this invite has expired",
            Deny::Revoked => "this invite was revoked",
            Deny::UsedUp => "this invite has been used up",
            Deny::UnknownInviter => "the inviter is not a member of this server",
            Deny::BadSignature => "this invite is damaged or forged",
        })
    }
}

impl std::error::Error for Deny {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invite {
    pub v: u8,
    pub cid: CommunityId,
    pub invite_id: InviteId,
    /// Absolute expiry in minutes since the Unix epoch; 0 = never.
    pub expires_min: u32,
    /// 0 = unlimited.
    pub max_uses: u8,
    /// The server name, at most 24 UTF-8 bytes.
    pub name: String,
    /// 1..=3 door IDs, the inviter's first.
    pub doors: Vec<MemberId>,
    pub sig: Signature,
}

fn now_min() -> u32 {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    u32::try_from(secs / 60).unwrap_or(u32::MAX)
}

fn clamp_invite_name(name: &str) -> String {
    let mut end = name.len().min(MAX_INVITE_NAME_BYTES);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    name[..end].to_string()
}

impl Invite {
    /// Makes an invite signed by `inviter`, whose own door goes first. `expires_in_min` of 0
    /// means it never expires.
    pub fn create(
        inviter: &Identity,
        state: &CommunityState,
        expires_in_min: u32,
        max_uses: u8,
        doors: &[MemberId],
    ) -> Invite {
        let mut all = vec![inviter.door_id()];
        for d in doors {
            if all.len() < MAX_DOORS && !all.contains(d) {
                all.push(*d);
            }
        }
        let mut inv = Invite {
            v: VERSION,
            cid: state.id,
            invite_id: InviteId::random(),
            expires_min: if expires_in_min == 0 { 0 } else { now_min().saturating_add(expires_in_min) },
            max_uses,
            name: clamp_invite_name(&state.name),
            doors: all,
            sig: Signature::from_bytes(&[0; 64]),
        };
        inv.sig = inviter.secret_key().sign(&inv.signed_bytes());
        inv
    }

    /// Everything before `sig`, which is also what the signature covers (after the domain tag).
    fn body(&self) -> Vec<u8> {
        let mut b = Vec::with_capacity(152);
        b.push(self.v);
        b.extend_from_slice(&self.cid.0);
        b.extend_from_slice(&self.invite_id.0);
        b.extend_from_slice(&self.expires_min.to_be_bytes());
        b.push(self.max_uses);
        b.push(self.name.len() as u8);
        b.extend_from_slice(self.name.as_bytes());
        b.push(self.doors.len() as u8);
        for d in &self.doors {
            b.extend_from_slice(&d.0);
        }
        b
    }

    fn signed_bytes(&self) -> Vec<u8> {
        let mut b = TAG.to_vec();
        b.extend(self.body());
        b
    }

    pub fn to_link(&self) -> String {
        let mut b = self.body();
        b.extend_from_slice(&self.sig.to_bytes());
        format!("{PREFIX}{}", b64::encode(&b))
    }

    /// Finds a link (or a bare code) in pasted text.
    pub fn parse(text: &str) -> Result<Invite> {
        let code = match text.to_ascii_lowercase().find(PREFIX) {
            // ASCII lowercasing keeps byte offsets, so the index is valid in `text`.
            Some(i) => {
                let rest = &text[i + PREFIX.len()..];
                let end = rest
                    .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
                    .unwrap_or(rest.len());
                &rest[..end]
            }
            None => text.trim(),
        };
        let Some(bytes) = b64::decode(code) else { bail!("not an invite link") };
        Self::from_bytes(&bytes)
    }

    fn from_bytes(b: &[u8]) -> Result<Invite> {
        let mut r = Reader(b);
        let v = r.take(1)?[0];
        ensure!(v == VERSION, "unsupported invite version {v}");
        let cid = CommunityId(r.array()?);
        let invite_id = InviteId(r.array()?);
        let expires_min = u32::from_be_bytes(r.array()?);
        let max_uses = r.take(1)?[0];
        let n = r.take(1)?[0] as usize;
        ensure!(n <= MAX_INVITE_NAME_BYTES, "invite name too long");
        let name = String::from_utf8(r.take(n)?.to_vec())?;
        let count = r.take(1)?[0] as usize;
        ensure!((1..=MAX_DOORS).contains(&count), "invite needs 1 to 3 doors");
        let mut doors = Vec::with_capacity(count);
        for _ in 0..count {
            doors.push(MemberId(r.array()?));
        }
        let sig = Signature::from_bytes(&r.array::<64>()?);
        ensure!(r.0.is_empty(), "trailing bytes in invite");
        Ok(Invite { v, cid, invite_id, expires_min, max_uses, name, doors, sig })
    }

    pub fn verify(&self, state: &CommunityState) -> Result<(), Deny> {
        self.verify_at(state, now_min())
    }

    /// `verify` at a given time, in minutes since the Unix epoch.
    pub fn verify_at(&self, state: &CommunityState, now_min: u32) -> Result<(), Deny> {
        if self.v != VERSION || self.cid != state.id {
            return Err(Deny::UnknownInviter);
        }
        let inviter = self
            .doors
            .first()
            .and_then(|door| state.members.values().find(|m| m.door == *door && state.verify_entry(m)))
            .ok_or(Deny::UnknownInviter)?;
        let key = iroh::PublicKey::from_bytes(&inviter.id.0).map_err(|_| Deny::BadSignature)?;
        key.verify(&self.signed_bytes(), &self.sig).map_err(|_| Deny::BadSignature)?;
        if state.revoked.contains(&self.invite_id) {
            return Err(Deny::Revoked);
        }
        if self.expires_min != 0 && now_min >= self.expires_min {
            return Err(Deny::Expired);
        }
        if self.max_uses > 0 {
            let used = state.members.values().filter(|m| m.via_invite == Some(self.invite_id)).count();
            if used >= self.max_uses as usize {
                return Err(Deny::UsedUp);
            }
        }
        Ok(())
    }
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        ensure!(self.0.len() >= n, "invite is too short");
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().expect("length checked"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::community::NewMember;

    fn ident(n: u8) -> Identity {
        Identity::from_secret_bytes([n; 32])
    }

    fn setup() -> (Identity, CommunityState) {
        let owner = ident(1);
        let state = CommunityState::for_tests("Friends", &[(&owner, "Owner", true)]);
        (owner, state)
    }

    #[test]
    fn roundtrip_and_verify() {
        let (owner, state) = setup();
        let extra = [ident(7).door_id(), ident(8).door_id()];
        let inv = Invite::create(&owner, &state, 60, 5, &extra);
        assert_eq!(inv.doors[0], owner.door_id());
        assert_eq!(inv.doors.len(), 3);
        let link = inv.to_link();
        assert!(link.starts_with("hubbub://join/"));
        let back = Invite::parse(&link).unwrap();
        assert_eq!(back, inv);
        assert_eq!(back.verify(&state), Ok(()));
        // The bare code works too, and duplicates / excess doors are dropped.
        assert_eq!(Invite::parse(link.strip_prefix(PREFIX).unwrap()).unwrap(), inv);
        let dup = Invite::create(&owner, &state, 0, 0, &[owner.door_id(), extra[0], extra[0], extra[1], ident(9).door_id()]);
        assert_eq!(dup.doors, vec![owner.door_id(), extra[0], extra[1]]);
        assert_eq!(dup.expires_min, 0);
    }

    #[test]
    fn flipped_byte_is_a_bad_signature() {
        let (owner, state) = setup();
        let inv = Invite::create(&owner, &state, 60, 5, &[]);
        let link = inv.to_link();
        let mut bytes = b64::decode(link.strip_prefix(PREFIX).unwrap()).unwrap();
        bytes[26] ^= 1; // a byte of max_uses / name area: still parses
        let forged = Invite::parse(&format!("{PREFIX}{}", b64::encode(&bytes)));
        if let Ok(f) = forged {
            assert_eq!(f.verify(&state), Err(Deny::BadSignature));
        }
        // Flip every byte in turn: nothing forged may verify.
        let good = b64::decode(link.strip_prefix(PREFIX).unwrap()).unwrap();
        for i in 0..good.len() {
            let mut b = good.clone();
            b[i] ^= 1;
            if let Ok(f) = Invite::from_bytes(&b) {
                assert!(f.verify_at(&state, 0).is_err(), "byte {i}");
            }
        }
        // A name byte specifically.
        let mut b = good.clone();
        b[1 + 16 + 8 + 4 + 1 + 1] ^= 1;
        assert_eq!(Invite::from_bytes(&b).unwrap().verify(&state), Err(Deny::BadSignature));
    }

    #[test]
    fn longest_link_fits_310_chars() {
        let owner = ident(1);
        let state = CommunityState::for_tests("ééééééééééééééééééé", &[(&owner, "Owner", true)]);
        let inv = Invite::create(&owner, &state, 60, 1, &[ident(2).door_id(), ident(3).door_id()]);
        assert_eq!(inv.name.len(), 24, "truncated on a char boundary");
        let bytes = b64::decode(inv.to_link().strip_prefix(PREFIX).unwrap()).unwrap();
        assert_eq!(bytes.len(), 216);
        assert!(inv.to_link().len() <= 310, "{}", inv.to_link().len());
    }

    #[test]
    fn name_truncates_on_char_boundary() {
        assert_eq!(clamp_invite_name("é".repeat(13).as_str()).len(), 24);
        assert_eq!(clamp_invite_name("abc"), "abc");
        assert_eq!(clamp_invite_name(&"a".repeat(30)).len(), 24);
    }

    #[test]
    fn parses_inside_a_sms_sentence() {
        let (owner, state) = setup();
        let inv = Invite::create(&owner, &state, 60, 0, &[]);
        let link = inv.to_link();
        for text in [
            format!("hey join my server: {link}. see you there!"),
            format!("({link})"),
            format!("<{link}>"),
            format!("  \n{}\n  ", link.to_uppercase().replace("HUBBUB://JOIN/", "HuBBuB://Join/")),
            format!("{link},"),
        ] {
            let got = Invite::parse(&text);
            if text.contains(&link) {
                assert_eq!(got.unwrap(), inv, "{text}");
            }
        }
        assert!(Invite::parse("no link here").is_err());
        assert!(Invite::parse("hubbub://join/AAAA").is_err());
        assert!(Invite::parse("").is_err());
    }

    #[test]
    fn rejects_unknown_version_and_wrong_lengths() {
        let (owner, state) = setup();
        let link = Invite::create(&owner, &state, 0, 0, &[]).to_link();
        let good = b64::decode(link.strip_prefix(PREFIX).unwrap()).unwrap();
        let mut v2 = good.clone();
        v2[0] = 2;
        assert!(Invite::from_bytes(&v2).is_err());
        let mut long = good.clone();
        long.push(0);
        assert!(Invite::from_bytes(&long).is_err());
        assert!(Invite::from_bytes(&good[..good.len() - 1]).is_err());
    }

    #[test]
    fn expiry_boundaries() {
        let (owner, state) = setup();
        let mut inv = Invite::create(&owner, &state, 60, 0, &[]);
        inv.expires_min = 1000;
        inv.sig = owner.secret_key().sign(&inv.signed_bytes());
        assert_eq!(inv.verify_at(&state, 999), Ok(()));
        assert_eq!(inv.verify_at(&state, 1000), Err(Deny::Expired));
        assert_eq!(inv.verify_at(&state, 1001), Err(Deny::Expired));
        let never = Invite::create(&owner, &state, 0, 0, &[]);
        assert_eq!(never.verify_at(&state, u32::MAX), Ok(()));
        // The clock-based create lands about `expires_in` ahead.
        let live = Invite::create(&owner, &state, 60, 0, &[]);
        assert!(live.expires_min >= now_min() + 59);
        assert_eq!(live.verify(&state), Ok(()));
    }

    #[test]
    fn revoked_wrong_community_and_unknown_inviter() {
        let (owner, mut state) = setup();
        let inv = Invite::create(&owner, &state, 0, 0, &[]);
        assert!(state.revoke(inv.invite_id));
        assert_eq!(inv.verify(&state), Err(Deny::Revoked));

        let other = CommunityState::for_tests("Other", &[(&owner, "Owner", true)]);
        assert_eq!(inv.verify(&other), Err(Deny::UnknownInviter));

        // Signed by a stranger whose door heads the list.
        let (_, state) = setup();
        let stranger = ident(50);
        let inv = Invite::create(&stranger, &state, 0, 0, &[]);
        assert_eq!(inv.verify(&state), Err(Deny::UnknownInviter));

        // A member's door with someone else's signature.
        let mut forged = Invite::create(&owner, &state, 0, 0, &[]);
        forged.sig = stranger.secret_key().sign(&forged.signed_bytes());
        assert_eq!(forged.verify(&state), Err(Deny::BadSignature));
    }

    #[test]
    fn used_up_counts_via_invite_entries() {
        let (owner, mut state) = setup();
        let inv = Invite::create(&owner, &state, 0, 2, &[]);
        let other = Invite::create(&owner, &state, 0, 2, &[]);
        let join = |state: &mut CommunityState, n: u8, via: Option<InviteId>| {
            let i = ident(n);
            state
                .admit(&owner, NewMember { id: i.member_id(), name: format!("m{n}"), can_host: false, door: i.door_id(), via_invite: via })
                .unwrap();
        };
        join(&mut state, 10, Some(other.invite_id));
        join(&mut state, 11, None);
        assert_eq!(inv.verify(&state), Ok(()));
        join(&mut state, 12, Some(inv.invite_id));
        assert_eq!(inv.verify(&state), Ok(()));
        join(&mut state, 13, Some(inv.invite_id));
        assert_eq!(inv.verify(&state), Err(Deny::UsedUp));
        assert_eq!(other.verify(&state), Ok(()));
        let unlimited = Invite::create(&owner, &state, 0, 0, &[]);
        assert_eq!(unlimited.verify(&state), Ok(()));
    }
}
