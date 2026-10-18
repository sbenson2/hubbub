//! base64url without padding, for ids, signatures and invite links: hex would not fit 150 members in a frame.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Encodes `bytes` as base64url without padding.
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

/// Decodes canonical unpadded base64url; `None` for anything else.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn b64_roundtrips_and_rejects_junk() {
        for len in 0..10usize {
            let b: Vec<u8> = (0..len as u8).map(|x| x.wrapping_mul(37)).collect();
            assert_eq!(decode(&encode(&b)).unwrap(), b);
        }
        assert_eq!(encode(&[0xfb, 0xff]), "-_8");
        assert!(decode("A").is_none());
        assert!(decode("A=").is_none());
        assert!(decode("AB").is_none(), "non-canonical trailing bits");
    }
}
