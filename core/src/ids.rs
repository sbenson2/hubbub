//! Member identifiers: a member is its 32-byte public key.
use std::fmt;
use std::str::FromStr;

use serde::{de, Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MemberId(pub [u8; 32]);

impl MemberId {
    /// First 4 hex characters, uppercase: a short label for humans.
    pub fn tag(&self) -> String {
        hex::encode(&self.0[..2]).to_uppercase()
    }
}

impl fmt::Display for MemberId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

impl fmt::Debug for MemberId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "MemberId({})", self)
    }
}

impl FromStr for MemberId {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut out = [0u8; 32];
        hex::decode_to_slice(s, &mut out)
            .map_err(|e| anyhow::anyhow!("invalid member id (need 64 hex chars): {e}"))?;
        Ok(MemberId(out))
    }
}

impl Serialize for MemberId {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for MemberId {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        s.parse().map_err(de::Error::custom)
    }
}

/// A fixed-size random identifier, shown and serialized as lowercase hex.
macro_rules! hex_id {
    ($(#[$doc:meta])* $name:ident, $len:literal, $what:literal) => {
        $(#[$doc])*
        #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(pub [u8; $len]);

        impl $name {
            pub fn random() -> Self {
                let mut b = [0u8; $len];
                getrandom::fill(&mut b).expect("system randomness unavailable");
                $name(b)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&hex::encode(self.0))
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, concat!(stringify!($name), "({})"), self)
            }
        }

        impl FromStr for $name {
            type Err = anyhow::Error;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                let mut out = [0u8; $len];
                hex::decode_to_slice(s, &mut out)
                    .map_err(|e| anyhow::anyhow!(concat!("invalid ", $what, " (need ", stringify!($len), " bytes as hex): {}"), e))?;
                Ok($name(out))
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&self.to_string())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = String::deserialize(d)?;
                s.parse().map_err(de::Error::custom)
            }
        }
    };
}

hex_id!(
    /// Names a community: 16 random bytes chosen by its creator.
    CommunityId, 16, "community id"
);
hex_id!(
    /// Names one invite: 8 random bytes chosen by the inviter.
    InviteId, 8, "invite id"
);

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn community_and_invite_ids_roundtrip_as_hex() {
        let c = CommunityId::random();
        assert_eq!(c.to_string().len(), 32);
        assert_eq!(c.to_string().parse::<CommunityId>().unwrap(), c);
        let i = InviteId([0xab; 8]);
        assert_eq!(serde_json::to_string(&i).unwrap(), "\"abababababababab\"");
        assert_eq!(serde_json::from_str::<InviteId>("\"abababababababab\"").unwrap(), i);
        assert!("abab".parse::<InviteId>().is_err());
    }
}
