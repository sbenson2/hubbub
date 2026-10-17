//! The community file: name, shared secret, and the member list.
//! Spike-only: copied between machines by hand.
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::ids::MemberId;
use crate::text::{check_channel_name, Channels};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemberEntry {
    pub id: MemberId,
    pub name: String,
    pub can_host: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommunityFile {
    pub name: String,
    pub secret_hex: String,
    pub members: Vec<MemberEntry>,
    /// Absent in older files and by default: see `Channels::default`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<Channels>,
}

impl CommunityFile {
    pub fn create(name: &str) -> Self {
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret).expect("system randomness unavailable");
        CommunityFile { name: name.to_string(), secret_hex: hex::encode(secret), members: Vec::new(), channels: None }
    }

    pub fn load(path: &Path) -> Result<Self> {
        let s = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let c: CommunityFile = serde_json::from_str(&s).with_context(|| format!("parsing {}", path.display()))?;
        // Text channel names become file names in the local store.
        for name in &c.channels().text {
            check_channel_name(name).with_context(|| format!("{}: text channels", path.display()))?;
        }
        Ok(c)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let s = serde_json::to_string_pretty(self)?;
        fs::write(path, s).with_context(|| format!("writing {}", path.display()))
    }

    /// Adds a member, replacing any existing entry with the same id.
    pub fn add_member(&mut self, e: MemberEntry) {
        self.members.retain(|m| m.id != e.id);
        self.members.push(e);
    }

    pub fn is_member(&self, id: &MemberId) -> bool {
        self.member(id).is_some()
    }

    pub fn member(&self, id: &MemberId) -> Option<&MemberEntry> {
        self.members.iter().find(|m| &m.id == id)
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
        let secret = hex::decode(&self.secret_hex).expect("secret_hex must be valid hex");
        let mut out = [0u8; 32];
        Hkdf::<Sha256>::new(None, &secret).expand(info, &mut out).expect("32 bytes is a valid HKDF output length");
        out
    }

    /// The community's text and voice channels: the listed ones, or the defaults.
    pub fn channels(&self) -> Channels {
        self.channels.clone().unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use crate::community::{CommunityFile, MemberEntry};
    use crate::identity::Identity;
    #[test] fn community_roundtrip_membership_and_key() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        let mut c = CommunityFile::create("test");
        let id = Identity::load_or_create(d.path()).unwrap().member_id();
        c.add_member(MemberEntry { id, name: "mini".into(), can_host: true });
        c.save(&p).unwrap();
        let l = CommunityFile::load(&p).unwrap();
        assert!(l.is_member(&id));
        assert_eq!(l.e2ee_key(), c.e2ee_key());
        assert_ne!(CommunityFile::create("other").e2ee_key(), c.e2ee_key());
    }
}
