//! The local node identity: an ed25519 key persisted in the data dir.
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use hkdf::Hkdf;
use sha2::Sha256;

use crate::ids::MemberId;

pub struct Identity {
    secret: [u8; 32],
}

impl Identity {
    /// Load `<dir>/identity.key` (32 raw bytes), creating it (mode 0600 on unix) if absent.
    pub fn load_or_create(dir: &Path) -> Result<Identity> {
        let path = dir.join("identity.key");
        if path.exists() {
            let bytes = fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
            let secret: [u8; 32] = bytes
                .try_into()
                .map_err(|_| anyhow::anyhow!("{} must be exactly 32 bytes", path.display()))?;
            return Ok(Identity { secret });
        }
        fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret).map_err(|e| anyhow::anyhow!("random bytes: {e}"))?;
        write_private(&path, &secret)?;
        Ok(Identity { secret })
    }

    /// An identity from raw key bytes, for tests that need many without temp dirs.
    #[cfg(any(test, feature = "test-util"))]
    pub fn from_secret_bytes(secret: [u8; 32]) -> Identity {
        Identity { secret }
    }

    pub fn secret_key(&self) -> iroh::SecretKey {
        iroh::SecretKey::from_bytes(&self.secret)
    }

    pub fn member_id(&self) -> MemberId {
        MemberId(*self.secret_key().public().as_bytes())
    }

    /// The key of this member's join door, a second endpoint that strangers may dial:
    /// HKDF-SHA256 over the identity's secret bytes, info `hubbub door v1`, no salt.
    /// Deterministic, and unrelated to the member key, so the door's address says nothing
    /// about the member's own endpoint.
    pub fn door_secret(&self) -> iroh::SecretKey {
        let mut out = [0u8; 32];
        Hkdf::<Sha256>::new(None, &self.secret)
            .expand(b"hubbub door v1", &mut out)
            .expect("32 bytes is a valid HKDF output length");
        iroh::SecretKey::from_bytes(&out)
    }

    pub fn door_id(&self) -> MemberId {
        MemberId(*self.door_secret().public().as_bytes())
    }
}

#[cfg(unix)]
fn write_private(path: &Path, data: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("creating {}", path.display()))?;
    f.write_all(data)?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private(path: &Path, data: &[u8]) -> Result<()> {
    fs::write(path, data).with_context(|| format!("writing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use crate::identity::Identity;
    use crate::ids::MemberId;
    #[test] fn identity_persists_across_loads() {
        let d = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(d.path()).unwrap();
        let b = Identity::load_or_create(d.path()).unwrap();
        assert_eq!(a.member_id(), b.member_id());
    }
    #[test] fn door_key_is_deterministic_and_not_the_member_key() {
        let d = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(d.path()).unwrap();
        let b = Identity::load_or_create(d.path()).unwrap();
        assert_eq!(a.door_id(), b.door_id());
        assert_eq!(a.door_secret().to_bytes(), b.door_secret().to_bytes());
        assert_ne!(a.door_id(), a.member_id());
        let other = Identity::load_or_create(tempfile::tempdir().unwrap().path()).unwrap();
        assert_ne!(a.door_id(), other.door_id());
    }
    #[test] fn tag_is_first_four_hex_upper() {
        let id = MemberId([0x4f, 0x2a, 0, 0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]);
        assert_eq!(id.tag(), "4F2A");
        assert_eq!(id.to_string().parse::<MemberId>().unwrap(), id);
    }
}
