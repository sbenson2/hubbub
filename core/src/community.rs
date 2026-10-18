//! Community state v2: name, shared secret, channels, revoked invites and a signed member
//! list that merges from any peer. Every member entry is signed by the member that admitted
//! it, and the chain of admitters ends at the owner, who signs their own entry. A peer that
//! missed an update can still prove its membership, and states converge by union.
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use anyhow::{bail, ensure, Context, Result};
use hkdf::Hkdf;
use iroh::Signature;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::identity::Identity;
use crate::ids::{CommunityId, InviteId, MemberId};
use crate::text::{check_channel_name, Channels};

/// A member's display name holds at most this many characters (Discord's limit) ...
pub const MAX_NAME_CHARS: usize = 32;
/// ... and at most this many UTF-8 bytes, which keeps 150 members inside one control frame.
pub const MAX_NAME_BYTES: usize = 64;

/// Cuts `name` to the limits on a character boundary.
pub fn clamp_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars().take(MAX_NAME_CHARS) {
        if out.len() + c.len_utf8() > MAX_NAME_BYTES {
            break;
        }
        out.push(c);
    }
    out
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemberEntry {
    #[serde(with = "id_b64")]
    pub id: MemberId,
    pub name: String,
    pub can_host: bool,
    /// The member's join door (see `Identity::door_id`).
    #[serde(with = "id_b64")]
    pub door: MemberId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via_invite: Option<InviteId>,
    #[serde(with = "id_b64")]
    pub admitted_by: MemberId,
    /// The admitter's signature over `signing_bytes`.
    #[serde(with = "sig_b64")]
    pub sig: Signature,
}

/// What an admitter supplies about a new member; `admit` adds the signature.
#[derive(Clone, Debug)]
pub struct NewMember {
    pub id: MemberId,
    pub name: String,
    pub can_host: bool,
    pub door: MemberId,
    pub via_invite: Option<InviteId>,
}

impl MemberEntry {
    /// The order that settles two entries for one member: lowest `(admitted_by, sig)` bytes.
    fn rank(&self) -> ([u8; 32], [u8; 64]) {
        (self.admitted_by.0, self.sig.to_bytes())
    }

    /// The bytes the admitter signs. Not JSON: a fixed layout under a domain tag, with the
    /// community id so an entry cannot be replayed into another community.
    fn signing_bytes(&self, cid: &CommunityId) -> Vec<u8> {
        let mut b = Vec::with_capacity(256);
        b.extend_from_slice(b"hubbub member v1");
        b.extend_from_slice(&cid.0);
        b.extend_from_slice(&self.id.0);
        b.extend_from_slice(&(self.name.len() as u32).to_be_bytes());
        b.extend_from_slice(self.name.as_bytes());
        b.push(self.can_host as u8);
        b.extend_from_slice(&self.door.0);
        match &self.via_invite {
            None => b.push(0),
            Some(i) => {
                b.push(1);
                b.extend_from_slice(&i.0);
            }
        }
        b.extend_from_slice(&self.admitted_by.0);
        b
    }

    fn signature_ok(&self, cid: &CommunityId) -> bool {
        iroh::PublicKey::from_bytes(&self.admitted_by.0)
            .is_ok_and(|k| k.verify(&self.signing_bytes(cid), &self.sig).is_ok())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommunityState {
    pub id: CommunityId,
    pub name: String,
    pub owner: MemberId,
    /// The shared E2EE and text key. Absent in `public_view()`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret_hex: Option<String>,
    /// Not merged: each peer keeps its own list (spike).
    #[serde(default)]
    pub channels: Channels,
    #[serde(default)]
    pub revoked: BTreeSet<InviteId>,
    #[serde(with = "members_vec")]
    pub members: BTreeMap<MemberId, MemberEntry>,
}

impl CommunityState {
    /// A new community owned by `owner`, who is its first member and signs their own entry.
    pub fn create(name: &str, owner: &Identity, can_host: bool) -> Self {
        Self::create_as(name, owner, &owner.member_id().tag(), can_host)
    }

    /// Like `create`, with the owner's display name.
    pub fn create_as(name: &str, owner: &Identity, owner_name: &str, can_host: bool) -> Self {
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret).expect("system randomness unavailable");
        let id = owner.member_id();
        let mut s = CommunityState {
            id: CommunityId::random(),
            name: name.to_string(),
            owner: id,
            secret_hex: Some(hex::encode(secret)),
            channels: Channels::default(),
            revoked: BTreeSet::new(),
            members: BTreeMap::new(),
        };
        let entry = s.signed_entry(owner, NewMember { id, name: owner_name.to_string(), can_host, door: owner.door_id(), via_invite: None });
        s.members.insert(id, entry);
        s
    }

    fn signed_entry(&self, admitter: &Identity, m: NewMember) -> MemberEntry {
        let mut e = MemberEntry {
            id: m.id,
            name: clamp_name(&m.name),
            can_host: m.can_host,
            door: m.door,
            via_invite: m.via_invite,
            admitted_by: admitter.member_id(),
            // Replaced below, once the entry has the fields the signature covers.
            sig: admitter.secret_key().sign(b""),
        };
        e.sig = admitter.secret_key().sign(&e.signing_bytes(&self.id));
        e
    }

    /// Adds `m`, signed by `admitter`, who must be a verified member. Names are cut to
    /// `MAX_NAME_CHARS` / `MAX_NAME_BYTES`. A member already present is left as it is.
    pub fn admit(&mut self, admitter: &Identity, m: NewMember) -> Result<()> {
        let by = admitter.member_id();
        let admitter_entry = self.members.get(&by).with_context(|| format!("{by} is not a member of this community"))?;
        ensure!(self.verify_entry(admitter_entry), "{by} is not a verified member of this community");
        if self.members.contains_key(&m.id) {
            return Ok(());
        }
        let e = self.signed_entry(admitter, m);
        self.members.insert(e.id, e);
        Ok(())
    }

    /// Whether `e` is a genuine entry of this community: its signature holds, and the chain of
    /// admitters recorded in this state, each with a good signature, ends at the owner's
    /// self-signed entry. `e` need not be in the state yet, but its admitter must be.
    pub fn verify_entry(&self, e: &MemberEntry) -> bool {
        if !entry_well_formed(&self.id, e) {
            return false;
        }
        if e.id == self.owner {
            return e.admitted_by == self.owner;
        }
        if e.admitted_by == e.id {
            return false;
        }
        let mut seen = BTreeSet::new();
        let mut cur = e.admitted_by;
        loop {
            if !seen.insert(cur) {
                return false; // a cycle
            }
            let Some(a) = self.members.get(&cur) else { return false };
            if a.id != cur || !entry_well_formed(&self.id, a) {
                return false;
            }
            if a.id == self.owner {
                return a.admitted_by == self.owner;
            }
            if a.admitted_by == a.id {
                return false;
            }
            cur = a.admitted_by;
        }
    }

    /// Records an invite as revoked. Any member may revoke (no signature in this spike).
    pub fn revoke(&mut self, invite: InviteId) -> bool {
        self.revoked.insert(invite)
    }

    /// Folds `other` into this state: revoked invites and members are unioned, and only entries
    /// that verify against the merged state are kept (the others are dropped, not an error).
    /// Two entries for one member keep the lowest `(admitted_by, sig)`. The result does not
    /// depend on the order of merging. This state's secret is never removed; a state without
    /// one takes `other`'s. Returns whether anything changed; fails if `other` is another
    /// community or has another owner.
    pub fn merge(&mut self, other: &CommunityState) -> Result<bool> {
        ensure!(self.id == other.id, "state is for another community ({} not {})", other.id, self.id);
        ensure!(self.owner == other.owner, "state has another owner ({} not {})", other.owner, self.owner);
        let pool: Vec<&MemberEntry> = self.members.values().chain(other.members.values()).collect();
        let sound: Vec<&MemberEntry> = pool.into_iter().filter(|e| entry_well_formed(&self.id, e)).collect();

        // Everyone reachable from the owner's self-signed entry through sound admissions.
        let mut reach = BTreeSet::new();
        if sound.iter().any(|e| e.id == self.owner && e.admitted_by == self.owner) {
            reach.insert(self.owner);
            loop {
                let before = reach.len();
                for e in &sound {
                    if e.id != e.admitted_by && reach.contains(&e.admitted_by) {
                        reach.insert(e.id);
                    }
                }
                if reach.len() == before {
                    break;
                }
            }
        }
        let mut chosen: BTreeMap<MemberId, MemberEntry> = BTreeMap::new();
        for e in sound {
            let admitted = if e.id == self.owner { e.admitted_by == self.owner } else { reach.contains(&e.admitted_by) && reach.contains(&e.id) && e.admitted_by != e.id };
            if admitted && chosen.get(&e.id).is_none_or(|c| e.rank() < c.rank()) {
                chosen.insert(e.id, e.clone());
            }
        }
        // The chosen entries might not chain to the owner among themselves (two members each
        // admitted by the other in their winning entries): drop those until all verify.
        let mut view = CommunityState { members: chosen, ..self.clone() };
        loop {
            let bad: Vec<MemberId> = view.members.values().filter(|e| !view.verify_entry(e)).map(|e| e.id).collect();
            if bad.is_empty() {
                break;
            }
            for id in bad {
                view.members.remove(&id);
            }
        }

        let revoked: BTreeSet<InviteId> = self.revoked.union(&other.revoked).copied().collect();
        let adopt_secret = self.secret_hex.is_none() && other.secret_hex.is_some();
        let changed = view.members != self.members || revoked != self.revoked || adopt_secret;
        self.members = view.members;
        self.revoked = revoked;
        if adopt_secret {
            self.secret_hex = other.secret_hex.clone();
        }
        Ok(changed)
    }

    /// This state without the secret: what goes into a `StateSync`.
    pub fn public_view(&self) -> CommunityState {
        CommunityState { secret_hex: None, ..self.clone() }
    }

    /// Reads a state file. Fails for an old v1 community file, a bad channel name, or a member
    /// entry that does not verify.
    pub fn load(path: &Path) -> Result<Self> {
        let s = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let v: serde_json::Value = serde_json::from_str(&s).with_context(|| format!("parsing {}", path.display()))?;
        if v.get("owner").is_none() || v.get("id").is_none() {
            bail!(
                "{} is an old (v1) community file, which this version cannot read: create the community again",
                path.display()
            );
        }
        let c: CommunityState = serde_json::from_value(v).with_context(|| format!("parsing {}", path.display()))?;
        // Text channel names become file names in the local store.
        for name in &c.channels.text {
            check_channel_name(name).with_context(|| format!("{}: text channels", path.display()))?;
        }
        if let Some(h) = &c.secret_hex {
            hex::decode(h).with_context(|| format!("{}: secret_hex", path.display()))?;
        }
        for e in c.members.values() {
            ensure!(c.verify_entry(e), "{}: the entry for member {} does not verify", path.display(), e.id);
        }
        Ok(c)
    }

    /// Writes a temp file beside `path`, then renames it over `path`, so a crash leaves the
    /// old file or the new one, never half of one.
    pub fn save_atomic(&self, path: &Path) -> Result<()> {
        self.save_with(path, || Ok(()))
    }

    fn save_with(&self, path: &Path, before_rename: impl FnOnce() -> Result<()>) -> Result<()> {
        let s = serde_json::to_string_pretty(self)?;
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = std::path::PathBuf::from(tmp);
        fs::write(&tmp, s).with_context(|| format!("writing {}", tmp.display()))?;
        before_rename()?;
        fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))
    }

    pub fn is_member(&self, id: &MemberId) -> bool {
        self.members.contains_key(id)
    }

    pub fn member(&self, id: &MemberId) -> Option<&MemberEntry> {
        self.members.get(id)
    }

    /// The media key: HKDF-SHA256 over the secret bytes, info `hubbub-spike-e2ee-v0`, no salt.
    pub fn e2ee_key(&self) -> [u8; 32] {
        self.derive_key(b"hubbub-spike-e2ee-v0")
    }

    /// The text-channel key: HKDF-SHA256 over the secret bytes, info `hubbub text v0`, no salt.
    pub fn text_key(&self) -> [u8; 32] {
        self.derive_key(b"hubbub text v0")
    }

    fn derive_key(&self, info: &[u8]) -> [u8; 32] {
        let hex = self.secret_hex.as_deref().expect("this state is a public view and has no secret");
        let secret = hex::decode(hex).expect("secret_hex must be valid hex");
        let mut out = [0u8; 32];
        Hkdf::<Sha256>::new(None, &secret).expand(info, &mut out).expect("32 bytes is a valid HKDF output length");
        out
    }

    /// The community's text and voice channels.
    pub fn channels(&self) -> Channels {
        self.channels.clone()
    }

    /// Tests: a community owned by the first identity, with the others admitted by the owner.
    /// Each is `(identity, name, can_host)`.
    #[cfg(any(test, feature = "test-util"))]
    pub fn for_tests(name: &str, members: &[(&Identity, &str, bool)]) -> Self {
        let (owner, owner_name, host) = members[0];
        let mut s = CommunityState::create_as(name, owner, owner_name, host);
        for (id, n, host) in &members[1..] {
            s.admit(owner, NewMember { id: id.member_id(), name: n.to_string(), can_host: *host, door: id.door_id(), via_invite: None })
                .unwrap();
        }
        s
    }
}

fn entry_well_formed(cid: &CommunityId, e: &MemberEntry) -> bool {
    e.name == clamp_name(&e.name) && e.signature_ok(cid)
}

/// base64url without padding, for ids and signatures: hex would not fit 150 members in a frame.
mod b64 {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    pub fn encode(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
            for i in 0..=chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            }
        }
        out
    }

    pub fn decode(s: &str) -> Option<Vec<u8>> {
        if s.len() % 4 == 1 {
            return None;
        }
        let mut out = Vec::with_capacity(s.len() * 3 / 4);
        for chunk in s.as_bytes().chunks(4) {
            let mut n = 0u32;
            for (i, c) in chunk.iter().enumerate() {
                let v = ALPHABET.iter().position(|a| a == c)? as u32;
                n |= v << (18 - 6 * i);
            }
            for i in 0..chunk.len() - 1 {
                out.push((n >> (16 - 8 * i)) as u8);
            }
        }
        // Reject non-canonical trailing bits so each value has one spelling.
        (encode(&out) == s).then_some(out)
    }
}

mod id_b64 {
    use serde::{de, Deserialize, Deserializer, Serializer};

    use super::b64;
    use crate::ids::MemberId;

    pub fn serialize<S: Serializer>(id: &MemberId, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&b64::encode(&id.0))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<MemberId, D::Error> {
        let s = String::deserialize(d)?;
        let b = b64::decode(&s).ok_or_else(|| de::Error::custom("invalid base64url id"))?;
        Ok(MemberId(b.try_into().map_err(|_| de::Error::custom("an id is 32 bytes"))?))
    }
}

mod sig_b64 {
    use iroh::Signature;
    use serde::{de, Deserialize, Deserializer, Serializer};

    use super::b64;

    pub fn serialize<S: Serializer>(sig: &Signature, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&b64::encode(&sig.to_bytes()))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Signature, D::Error> {
        let s = String::deserialize(d)?;
        let b = b64::decode(&s).ok_or_else(|| de::Error::custom("invalid base64url signature"))?;
        let b: [u8; 64] = b.try_into().map_err(|_| de::Error::custom("a signature is 64 bytes"))?;
        Ok(Signature::from_bytes(&b))
    }
}

/// Members as a JSON array (the id is in each entry), a map in memory.
mod members_vec {
    use std::collections::BTreeMap;

    use serde::{de, Deserialize, Deserializer, Serialize, Serializer};

    use super::MemberEntry;
    use crate::ids::MemberId;

    pub fn serialize<S: Serializer>(m: &BTreeMap<MemberId, MemberEntry>, s: S) -> Result<S::Ok, S::Error> {
        m.values().collect::<Vec<_>>().serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<BTreeMap<MemberId, MemberEntry>, D::Error> {
        let mut out = BTreeMap::new();
        for e in Vec::<MemberEntry>::deserialize(d)? {
            let id = e.id;
            if out.insert(id, e).is_some() {
                return Err(de::Error::custom(format!("member {id} is listed twice")));
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ident(n: u8) -> Identity {
        Identity::from_secret_bytes([n; 32])
    }

    fn new_member(i: &Identity, name: &str) -> NewMember {
        NewMember { id: i.member_id(), name: name.into(), can_host: true, door: i.door_id(), via_invite: None }
    }

    #[test]
    fn b64_roundtrips_and_rejects_junk() {
        for len in 0..10usize {
            let b: Vec<u8> = (0..len as u8).map(|x| x.wrapping_mul(37)).collect();
            assert_eq!(b64::decode(&b64::encode(&b)).unwrap(), b);
        }
        assert_eq!(b64::encode(&[0xfb, 0xff]), "-_8");
        assert!(b64::decode("A").is_none());
        assert!(b64::decode("A=").is_none());
        assert!(b64::decode("AB").is_none(), "non-canonical trailing bits");
    }

    #[test]
    fn roundtrip_membership_and_key() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        let (a, b) = (ident(1), ident(2));
        let mut c = CommunityState::create("test", &a, true);
        c.admit(&a, new_member(&b, "mini")).unwrap();
        c.save_atomic(&p).unwrap();
        let l = CommunityState::load(&p).unwrap();
        assert_eq!(l, c);
        assert!(l.is_member(&b.member_id()));
        assert_eq!(l.member(&b.member_id()).unwrap().door, b.door_id());
        assert_eq!(l.e2ee_key(), c.e2ee_key());
        assert_ne!(CommunityState::create("other", &a, true).e2ee_key(), c.e2ee_key());
        assert_ne!(c.text_key(), c.e2ee_key());
    }

    #[test]
    fn owner_signs_their_own_entry_and_it_verifies() {
        let o = ident(1);
        let c = CommunityState::create("c", &o, true);
        let e = c.member(&o.member_id()).unwrap();
        assert_eq!((e.admitted_by, e.id, c.owner), (o.member_id(), o.member_id(), o.member_id()));
        assert!(c.verify_entry(e));
    }

    #[test]
    fn a_forged_admitter_or_tampered_entry_is_rejected() {
        let (o, a, x, evil) = (ident(1), ident(2), ident(3), ident(4));
        let mut c = CommunityState::create("c", &o, true);
        c.admit(&o, new_member(&a, "alice")).unwrap();
        c.admit(&a, new_member(&x, "xavier")).unwrap();
        let good = c.member(&x.member_id()).unwrap().clone();
        assert!(c.verify_entry(&good));
        assert_eq!(good.admitted_by, a.member_id());

        let mut renamed = good.clone();
        renamed.name = "mallory".into();
        assert!(!c.verify_entry(&renamed), "tampered name");
        let mut host = good.clone();
        host.can_host = !host.can_host;
        assert!(!c.verify_entry(&host), "tampered can_host");
        let mut door = good.clone();
        door.door = evil.door_id();
        assert!(!c.verify_entry(&door), "tampered door");
        let mut via = good.clone();
        via.via_invite = Some(InviteId([1; 8]));
        assert!(!c.verify_entry(&via), "tampered via_invite");

        // Claims alice admitted it, but is signed by someone else.
        let mut forged = good.clone();
        forged.sig = evil.secret_key().sign(&forged.signing_bytes(&c.id));
        assert!(!c.verify_entry(&forged), "signature by a key that is not admitted_by");
        // Signed by a non-member who names themselves admitter.
        let mut outsider = c.signed_entry(&evil, new_member(&ident(5), "eve"));
        assert!(!c.verify_entry(&outsider), "admitter is not a member");
        // Self-admitted: not the owner, so no chain.
        outsider = c.signed_entry(&evil, new_member(&evil, "evil"));
        assert!(!c.verify_entry(&outsider), "self-signed non-owner");
        // A non-member cannot admit through the API either.
        assert!(c.admit(&evil, new_member(&ident(5), "eve")).is_err());
        // A genuine entry replayed into another community does not verify there.
        let other = CommunityState::create("c", &o, true);
        assert!(!other.verify_entry(&good));
        let mut moved = other.clone();
        moved.members.insert(good.id, good.clone());
        assert!(!moved.verify_entry(&good));
    }

    #[test]
    fn a_state_file_with_a_forged_entry_does_not_load() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        let (o, a) = (ident(1), ident(2));
        let mut c = CommunityState::create("c", &o, true);
        c.admit(&o, new_member(&a, "alice")).unwrap();
        c.members.get_mut(&a.member_id()).unwrap().name = "bob".into();
        c.save_atomic(&p).unwrap();
        assert!(CommunityState::load(&p).is_err());
    }

    #[test]
    fn an_old_v1_file_fails_with_a_clear_error() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        fs::write(&p, r#"{"name": "old", "secret_hex": "00ff", "members": []}"#).unwrap();
        let err = format!("{:#}", CommunityState::load(&p).unwrap_err());
        assert!(err.contains("old (v1) community file"), "{err}");
    }

    #[test]
    fn names_are_cut_to_the_limits_on_a_char_boundary() {
        let (o, a) = (ident(1), ident(2));
        let mut c = CommunityState::create("c", &o, true);
        c.admit(&o, new_member(&a, &"x".repeat(40))).unwrap();
        assert_eq!(c.member(&a.member_id()).unwrap().name, "x".repeat(MAX_NAME_CHARS));
        let b = ident(3);
        c.admit(&o, new_member(&b, &"é".repeat(40))).unwrap();
        assert_eq!(c.member(&b.member_id()).unwrap().name, "é".repeat(MAX_NAME_CHARS));
        let d = ident(4);
        c.admit(&o, new_member(&d, &"🦀".repeat(40))).unwrap();
        assert_eq!(c.member(&d.member_id()).unwrap().name, "🦀".repeat(MAX_NAME_BYTES / 4));
        assert!(c.members.values().all(|e| c.verify_entry(e)));
        // An over-long name that a peer signed anyway is not accepted.
        let mut long = c.signed_entry(&o, new_member(&ident(5), "n"));
        long.name = "y".repeat(33);
        long.sig = o.secret_key().sign(&long.signing_bytes(&c.id));
        assert!(!c.verify_entry(&long));
    }

    fn pair() -> (Identity, CommunityState) {
        let o = ident(1);
        (ident(1), CommunityState::create("c", &o, true))
    }

    #[test]
    fn merge_is_commutative_and_idempotent() {
        let (o, base) = pair();
        let (x, y, z) = (ident(2), ident(3), ident(4));
        let mut a = base.clone();
        a.admit(&o, new_member(&x, "x")).unwrap();
        a.admit(&x, new_member(&z, "z")).unwrap();
        a.revoke(InviteId([1; 8]));
        let mut b = base.clone();
        b.admit(&o, new_member(&y, "y")).unwrap();
        b.revoke(InviteId([2; 8]));

        let (mut ab, mut ba) = (a.clone(), b.clone());
        assert!(ab.merge(&b).unwrap());
        assert!(ba.merge(&a).unwrap());
        assert_eq!(ab, ba);
        assert_eq!(ab.members.len(), 4);
        assert_eq!(ab.revoked.len(), 2);
        assert!(!ab.merge(&b).unwrap(), "merging again changes nothing");
        assert!(!ab.merge(&a).unwrap());
        let again = ab.clone();
        ab.merge(&again).unwrap();
        assert_eq!(ab, again);
    }

    #[test]
    fn merge_with_a_conflict_keeps_the_lowest_admitter_and_signature_either_way() {
        let (o, base) = pair();
        let (x, y, z) = (ident(2), ident(3), ident(4));
        // y and the owner both admit z, in different replicas.
        let mut a = base.clone();
        a.admit(&o, new_member(&y, "y")).unwrap();
        let mut b = a.clone();
        a.admit(&o, new_member(&z, "z")).unwrap();
        b.admit(&y, new_member(&z, "z")).unwrap();
        let _ = x;
        let (mut ab, mut ba) = (a.clone(), b.clone());
        ab.merge(&b).unwrap();
        ba.merge(&a).unwrap();
        assert_eq!(ab, ba);
        let want = if o.member_id() < y.member_id() { o.member_id() } else { y.member_id() };
        assert_eq!(ab.member(&z.member_id()).unwrap().admitted_by, want);
        assert!(ab.members.values().all(|e| ab.verify_entry(e)));
    }

    #[test]
    fn merge_drops_unverifiable_entries_and_refuses_another_community_or_owner() {
        let (o, base) = pair();
        let (x, evil) = (ident(2), ident(9));
        let mut a = base.clone();
        a.admit(&o, new_member(&x, "x")).unwrap();
        let mut b = base.clone();
        // A forged entry, and an entry whose admitter is unknown.
        let forged = a.member(&x.member_id()).unwrap().clone();
        let mut tampered = forged.clone();
        tampered.name = "tampered".into();
        b.members.insert(tampered.id, tampered);
        let ghost = b.signed_entry(&evil, new_member(&ident(8), "ghost"));
        b.members.insert(ghost.id, ghost);
        let mut m = base.clone();
        m.merge(&b).unwrap();
        assert_eq!(m.members.len(), 1, "only the owner: {:?}", m.members.keys().collect::<Vec<_>>());
        m.merge(&a).unwrap();
        assert_eq!(m.members.len(), 2);

        let other_community = CommunityState::create("c", &o, true);
        assert!(m.merge(&other_community).is_err(), "another id");
        let mut other_owner = m.clone();
        other_owner.owner = evil.member_id();
        assert!(m.merge(&other_owner).is_err(), "another owner");
    }

    #[test]
    fn merge_drops_members_admitted_in_a_cycle() {
        let (o, base) = pair();
        let (x, y) = (ident(2), ident(3));
        let mut b = base.clone();
        let ex = b.signed_entry(&y, new_member(&x, "x"));
        let ey = b.signed_entry(&x, new_member(&y, "y"));
        b.members.insert(ex.id, ex);
        b.members.insert(ey.id, ey);
        let mut m = base.clone();
        m.merge(&b).unwrap();
        assert_eq!(m.members.len(), 1);
        let _ = o;
    }

    #[test]
    fn merge_keeps_the_secret_and_a_public_view_has_none() {
        let (o, base) = pair();
        let mut a = base.clone();
        a.admit(&o, new_member(&ident(2), "x")).unwrap();
        let view = a.public_view();
        assert!(view.secret_hex.is_none());
        assert!(!serde_json::to_string(&view).unwrap().contains("secret_hex"));
        let secret = base.secret_hex.clone();
        let mut m = base.clone();
        assert!(m.merge(&view).unwrap());
        assert_eq!(m.secret_hex, secret, "merging a public view keeps the secret");
        assert_eq!(m.members.len(), 2);
        // A state that has no secret takes one when it is offered.
        let mut blind = view.clone();
        blind.merge(&base).unwrap();
        assert_eq!(blind.secret_hex, secret);
    }

    #[test]
    fn a_150_member_public_view_fits_a_control_frame_with_headroom() {
        let o = ident(1);
        let mut c = CommunityState::create(&"c".repeat(MAX_NAME_CHARS), &o, true);
        let mut ids = vec![ident(1)];
        for n in 2..=150u8 {
            // Chains of several admitters, so the entries differ in who signed.
            let by = &ids[(n as usize - 2) / 3];
            let name = "é".repeat(MAX_NAME_CHARS); // the longest name: 32 chars, 64 bytes
            let m = ident(n);
            c.admit(by, NewMember { id: m.member_id(), name, can_host: true, door: m.door_id(), via_invite: Some(InviteId([n; 8])) })
                .unwrap();
            ids.push(m);
        }
        assert_eq!(c.members.len(), 150);
        assert!(c.members.values().all(|e| c.verify_entry(e)));
        // Same serializer and length-prefixed JSON framing as `proto::write_msg`, in an
        // envelope tagged like a CtlMsg.
        let body = serde_json::to_vec(&serde_json::json!({"t": "StateSync", "state": c.public_view()})).unwrap();
        assert!(body.len() + 1024 <= crate::proto::MAX_FRAME, "{} bytes leaves too little headroom", body.len());
        // And it comes back intact.
        let back: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let state: CommunityState = serde_json::from_value(back["state"].clone()).unwrap();
        assert_eq!(state, c.public_view());
    }

    #[test]
    fn an_interrupted_atomic_save_leaves_the_old_file_intact() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        let (o, mut c) = pair();
        c.save_atomic(&p).unwrap();
        let old = fs::read(&p).unwrap();
        c.admit(&o, new_member(&ident(2), "x")).unwrap();
        let err = c.save_with(&p, || bail!("power cut")).unwrap_err();
        assert!(format!("{err:#}").contains("power cut"));
        assert_eq!(fs::read(&p).unwrap(), old);
        assert_eq!(CommunityState::load(&p).unwrap().members.len(), 1);
        // The leftover temp file does not stop the next save.
        c.save_atomic(&p).unwrap();
        assert_eq!(CommunityState::load(&p).unwrap().members.len(), 2);
    }
}
