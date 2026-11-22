//! The cap and the proofs of `hello` (design 4.2).  The hub sends a nonce on accept; the client proves it read the cap
//! with an HMAC over both nonces, and the hub proves the same back.  The HMAC key is the cap's 64 hex characters as
//! ASCII bytes, as the Lisp `drgnx-hub-hmac` uses it.

use hmac::{Hmac, KeyInit, Mac};
use secrecy::{ExposeSecret, SecretString};
use sha2::Sha256;
use std::io::{self, Read};
use std::path::Path;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

/// The largest cap file read (bytes); a cap is 64.
const MAX_CAP_FILE: u64 = 256;

/// The cap: 32 random bytes as 64 lowercase hex, kept secret (no `Debug`, zeroed when dropped).
///
/// ```compile_fail
/// fn show(cap: &runstav::proof::Cap) -> String {
///     format!("{cap:?}")
/// }
/// ```
pub struct Cap(SecretString);

impl Cap {
    /// A new cap from the OS's random source.
    pub fn generate() -> io::Result<Cap> {
        let bytes = Zeroizing::new(random::<32>()?);
        Ok(Cap(SecretString::from(hex(&*bytes))))
    }

    /// The cap in FILE: refused when the file is over 256 bytes or is not exactly 64 lowercase hex.
    pub fn read(path: &Path) -> io::Result<Cap> {
        Cap::read_from(std::fs::File::open(path)?, path)
    }

    /// The cap in FILE, already open (a client opens it through its checked directory), named PATH in errors.
    pub fn read_from(file: std::fs::File, path: &Path) -> io::Result<Cap> {
        let mut text = Zeroizing::new(Vec::new());
        file.take(MAX_CAP_FILE + 1).read_to_end(&mut text)?;
        if text.len() as u64 > MAX_CAP_FILE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{} is over {MAX_CAP_FILE} bytes", path.display()),
            ));
        }
        if text.len() != 64 || !text.iter().all(|b| is_lower_hex(*b)) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{} is not 64 lowercase hex characters", path.display()),
            ));
        }
        let s = std::str::from_utf8(&text).expect("hex is ASCII");
        Ok(Cap(SecretString::from(s)))
    }

    /// The 64 hex characters (to write the cap file and to key the HMAC).
    pub fn expose(&self) -> &str {
        self.0.expose_secret()
    }
}

fn random<const N: usize>() -> io::Result<[u8; N]> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|e| io::Error::other(format!("no random bytes: {e}")))?;
    Ok(b)
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(char::from(DIGITS[usize::from(b >> 4)]));
        s.push(char::from(DIGITS[usize::from(b & 15)]));
    }
    s
}

fn is_lower_hex(b: u8) -> bool {
    b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
}

/// 64 lowercase hex as 32 bytes; anything else is none.
fn digest_of(s: &str) -> Option<[u8; 32]> {
    let s = s.as_bytes();
    if s.len() != 64 || !s.iter().all(|b| is_lower_hex(*b)) {
        return None;
    }
    let nibble = |b: u8| {
        if b.is_ascii_digit() {
            b - b'0'
        } else {
            b - b'a' + 10
        }
    };
    let mut out = [0u8; 32];
    for (i, &[hi, lo]) in s.as_chunks::<2>().0.iter().enumerate() {
        out[i] = (nibble(hi) << 4) | nibble(lo);
    }
    Some(out)
}

/// A nonce: 32 lowercase hex from 16 random bytes.
pub fn nonce() -> io::Result<String> {
    Ok(hex(&random::<16>()?))
}

/// HMAC-SHA256 of TEXT keyed with KEY, as 64 lowercase hex.
pub fn hmac_hex(key: &[u8], text: &str) -> String {
    let mut mac =
        <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC takes a key of any length");
    mac.update(text.as_bytes());
    hex(&mac.finalize().into_bytes())
}

/// The client's proof: over `"drgnx-hub client " + hub_nonce + " " + client_nonce`.
pub fn client_proof(cap: &Cap, hub_nonce: &str, client_nonce: &str) -> String {
    hmac_hex(
        cap.expose().as_bytes(),
        &format!("drgnx-hub client {hub_nonce} {client_nonce}"),
    )
}

/// The hub's proof back, sent only after a valid client proof: over `"drgnx-hub hub " + client_nonce + " " +
/// hub_nonce`.
pub fn hub_proof(cap: &Cap, client_nonce: &str, hub_nonce: &str) -> String {
    hmac_hex(
        cap.expose().as_bytes(),
        &format!("drgnx-hub hub {client_nonce} {hub_nonce}"),
    )
}

/// Whether GIVEN is the proof EXPECTED: both decoded from 64 lowercase hex to 32 bytes (a malformed one is never
/// valid), then compared in constant time.
pub fn verify(expected_hex: &str, given_hex: &str) -> bool {
    match (digest_of(expected_hex), digest_of(given_hex)) {
        (Some(e), Some(g)) => bool::from(e.ct_eq(&g)),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cap_of(hex: &str) -> Cap {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("hub-x.cap");
        std::fs::write(&f, hex).unwrap();
        Cap::read(&f).unwrap()
    }

    #[test]
    fn rfc_4231_case_2() {
        assert_eq!(
            hmac_hex(b"Jefe", "what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn proofs_bind_both_nonces() {
        let cap = Cap::generate().unwrap();
        let (h, c) = (nonce().unwrap(), nonce().unwrap());
        let (h2, c2) = (nonce().unwrap(), nonce().unwrap());
        let cp = client_proof(&cap, &h, &c);
        let hp = hub_proof(&cap, &c, &h);
        assert_eq!(cp.len(), 64);
        assert_ne!(cp, hp);
        assert_ne!(client_proof(&cap, &h2, &c), cp);
        assert_ne!(client_proof(&cap, &h, &c2), cp);
        assert_ne!(hub_proof(&cap, &c2, &h), hp);
        assert_ne!(hub_proof(&cap, &c, &h2), hp);
        // the same inputs give the same proof; another cap another one
        assert_eq!(client_proof(&cap, &h, &c), cp);
        assert_ne!(client_proof(&Cap::generate().unwrap(), &h, &c), cp);
        // the key is the cap's hex as ASCII (the Lisp hub's rule)
        let k = "ab".repeat(32);
        assert_eq!(
            client_proof(&cap_of(&k), "n1", "n2"),
            hmac_hex(k.as_bytes(), "drgnx-hub client n1 n2")
        );
    }

    #[test]
    fn verify_compares_decoded_digests() {
        let p = client_proof(
            &Cap::generate().unwrap(),
            &nonce().unwrap(),
            &nonce().unwrap(),
        );
        assert!(verify(&p, &p));
        assert!(verify(&p, &p.clone()));
        assert!(!verify(&p, &p.to_uppercase()), "an uppercase copy");
        assert!(
            !verify(&p.to_uppercase(), &p.to_uppercase()),
            "both uppercase"
        );
        assert!(!verify(&p, &p[..63]), "63 characters");
        assert!(!verify(&p[..63], &p[..63]), "both 63 characters");
        let nonhex = format!("{}zz", &p[..62]);
        assert!(!verify(&p, &nonhex), "not hex");
        assert!(!verify(&nonhex, &nonhex), "both not hex");
        assert!(!verify(&p, &format!("{p}00")), "longer");
        let mut other = p.clone().into_bytes();
        other[0] = if other[0] == b'0' { b'1' } else { b'0' };
        assert!(!verify(&p, std::str::from_utf8(&other).unwrap()));
    }

    #[test]
    fn caps_and_nonces_have_their_shape() {
        let lower_hex = |s: &str| {
            s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        let cap = Cap::generate().unwrap();
        assert_eq!(cap.expose().len(), 64);
        assert!(lower_hex(cap.expose()));
        assert_ne!(cap.expose(), Cap::generate().unwrap().expose());
        let n = nonce().unwrap();
        assert_eq!(n.len(), 32);
        assert!(lower_hex(&n));
        assert_ne!(n, nonce().unwrap());
    }

    #[test]
    fn cap_read_refuses_what_is_not_a_cap() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("hub-x.cap");
        let good = "0123456789abcdef".repeat(4);
        std::fs::write(&f, &good).unwrap();
        assert_eq!(Cap::read(&f).unwrap().expose(), good);
        for bad in [
            good.to_uppercase(),
            good[..63].to_string(),
            format!("{good}0"),
            format!("{good}\n"),
            format!("{}g", &good[..63]),
            String::new(),
            "a".repeat(257),
        ] {
            std::fs::write(&f, &bad).unwrap();
            assert!(Cap::read(&f).is_err(), "{bad:?}");
        }
        assert!(Cap::read(&dir.path().join("missing")).is_err());
    }
}
