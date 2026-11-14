//! Exact-value redaction (docs/guide/runners.md, "Keys"; design §6.3, M5): the hub knows the keys it sent to a job, so it
//! removes their bytes from what the job's runner returns before anyone reads it.
//!
//! - [`Redactor`] masks every value it holds in each of its forms: raw, base64 (standard and URL-safe, with and without
//!   padding) and percent-encoded (upper- and lower-case hex). A mask has the length of what it covers, so the hub's
//!   copy of a log keeps the runner's offsets.
//! - A value split across two chunks is masked too: the redactor holds back the end of a chunk that could begin a
//!   value, until the next chunk (or [`Redactor::finish`]) shows whether it does.
//! - [`notices`]: the `looks_like_secret` heuristic only says where a log may hold a secret ("this log may hold a
//!   secret at line N"). It never masks: it would shred digests and hashes.

use secrecy::{ExposeSecret, SecretString};
use zeroize::{Zeroize, Zeroizing};

/// The byte a mask is made of.
pub const MASK: u8 = b'*';

/// Masks the forms of the values it holds in a stream of chunks. No `Debug` or `Clone`: it holds keys, zeroed when it
/// goes.
#[derive(Default)]
pub struct Redactor {
    forms: Vec<Zeroizing<Vec<u8>>>,
    /// The end of the stream so far that could begin a form: held back until the next chunk.
    held: Zeroizing<Vec<u8>>,
}

const B64_STD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64_URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// V in base64 with ALPHABET, padded with `=` or not.
fn base64(v: &[u8], alphabet: &[u8; 64], pad: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len().div_ceil(3) * 4);
    for c in v.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        let digits = c.len() + 1;
        for i in 0..4 {
            if i < digits {
                out.push(alphabet[((n >> (18 - 6 * i)) & 63) as usize]);
            } else if pad {
                out.push(b'=');
            }
        }
    }
    out
}

/// V percent-encoded: every byte but RFC 3986's unreserved ones as `%XX`, in upper- or lower-case hex.
fn percent(v: &[u8], upper: bool) -> Vec<u8> {
    let hex: &[u8; 16] = if upper {
        b"0123456789ABCDEF"
    } else {
        b"0123456789abcdef"
    };
    let mut out = Vec::with_capacity(v.len() * 3);
    for &b in v {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b);
        } else {
            out.extend_from_slice(&[b'%', hex[usize::from(b >> 4)], hex[usize::from(b & 15)]]);
        }
    }
    out
}

impl Redactor {
    /// A redactor of VALUES (an empty one is no value).
    pub fn new(values: &[SecretString]) -> Redactor {
        let mut r = Redactor::default();
        for v in values {
            r.add(v);
        }
        r
    }

    /// VALUE is masked from here on too (a key sent after the stream began).
    pub fn add(&mut self, value: &SecretString) {
        let v = value.expose_secret().as_bytes();
        if v.is_empty() {
            return;
        }
        let mut forms = vec![
            v.to_vec(),
            base64(v, B64_STD, true),
            base64(v, B64_STD, false),
            base64(v, B64_URL, true),
            base64(v, B64_URL, false),
            percent(v, true),
            percent(v, false),
        ];
        forms.sort();
        forms.dedup();
        for f in forms {
            let f = Zeroizing::new(f);
            if !self.forms.contains(&f) {
                self.forms.push(f);
            }
        }
        // longest first: a form inside a longer one is masked by the longer
        self.forms.sort_by_key(|f| std::cmp::Reverse(f.len()));
    }

    /// How many bytes it holds back now.
    pub fn held(&self) -> usize {
        self.held.len()
    }

    /// CHUNK, the stream's next bytes: what may be written now, every form in it masked. The end that could begin a
    /// form is held back, so the output lags the input by [`Redactor::held`] bytes.
    pub fn redact(&mut self, chunk: &[u8]) -> Vec<u8> {
        let mut buf = std::mem::take(&mut *self.held);
        buf.extend_from_slice(chunk);
        self.mask(&mut buf);
        let keep = self.prefix_at_end(&buf);
        let out = buf[..buf.len() - keep].to_vec();
        self.held = Zeroizing::new(buf[buf.len() - keep..].to_vec());
        buf.zeroize();
        out
    }

    /// The rest of the stream: what was held back (it began no form after all).
    pub fn finish(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.held)
    }

    /// Masks every form in BUF, longest first.
    fn mask(&self, buf: &mut [u8]) {
        for f in &self.forms {
            let n = f.len();
            let mut i = 0;
            while i + n <= buf.len() {
                if buf[i..i + n] == f[..] {
                    buf[i..i + n].fill(MASK);
                    i += n;
                } else {
                    i += 1;
                }
            }
        }
    }

    /// The length of the longest end of BUF that is the beginning of a form (shorter than the form).
    fn prefix_at_end(&self, buf: &[u8]) -> usize {
        let mut keep = 0;
        for f in &self.forms {
            let most = (f.len() - 1).min(buf.len());
            for k in (keep + 1..=most).rev() {
                if buf[buf.len() - k..] == f[..k] {
                    keep = k;
                    break;
                }
            }
        }
        keep
    }
}

/// What the heuristic says of LOG: one notice per line that may hold a secret, never a change to the log.
pub fn notices(log: &[u8]) -> Vec<String> {
    log.split(|b| *b == b'\n')
        .enumerate()
        .filter(|(_, l)| runstav::secrets::looks_like_secret(&String::from_utf8_lossy(l)).is_some())
        .map(|(i, _)| format!("this log may hold a secret at line {}", i + 1))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secret(s: &str) -> SecretString {
        SecretString::from(s.to_string())
    }

    /// The test's key: made here, never a real one (split, so the repository's own secret check never sees it whole).
    fn key() -> String {
        format!("{}{}", "tok-", "s3cr3t+/value?=&")
    }

    // [D] pure: the raw, base64 (both alphabets, padded or not) and percent-encoded forms are masked, at their length
    #[test]
    fn redact_removes_raw_base64_and_url_forms() {
        let k = key();
        let v = k.as_bytes();
        let forms = [
            v.to_vec(),
            base64(v, B64_STD, true),
            base64(v, B64_STD, false),
            base64(v, B64_URL, true),
            base64(v, B64_URL, false),
            percent(v, true),
            percent(v, false),
        ];
        // the encoders are the standard ones: a known vector each
        assert_eq!(base64(b"foobar", B64_STD, true), b"Zm9vYmFy");
        assert_eq!(base64(b"fo", B64_STD, true), b"Zm8=");
        assert_eq!(base64(b"fo", B64_STD, false), b"Zm8");
        assert_eq!(base64(&[0xfb, 0xff], B64_URL, false), b"-_8");
        assert_eq!(percent(b"a b/?", true), b"a%20b%2F%3F");
        for form in &forms {
            let mut r = Redactor::new(&[secret(&k)]);
            let mut line = b"export TOKEN=".to_vec();
            line.extend_from_slice(form);
            line.extend_from_slice(b" done\n");
            let mut out = r.redact(&line);
            out.extend(r.finish());
            assert_eq!(out.len(), line.len(), "the offsets are kept");
            let text = String::from_utf8(out).unwrap();
            assert!(!text.contains(std::str::from_utf8(form).unwrap()), "{text}");
            assert_eq!(
                text,
                format!("export TOKEN={} done\n", "*".repeat(form.len()))
            );
        }
        // a log with none of them passes untouched, and an empty value masks nothing
        let mut r = Redactor::new(&[secret(&k), secret("")]);
        let plain = b"cargo test: 3 passed\n";
        let mut out = r.redact(plain);
        out.extend(r.finish());
        assert_eq!(out, plain);
    }

    // [D] pure: a value split across two chunks (at every point) is masked, and nothing of it is ever written first
    #[test]
    fn redact_across_a_chunk_boundary() {
        let k = key();
        let log = format!("before {k} middle {k}after\n");
        let want = log.replace(&k, &"*".repeat(k.len()));
        for cut in 0..=log.len() {
            let mut r = Redactor::new(&[secret(&k)]);
            let mut out = r.redact(&log.as_bytes()[..cut]);
            assert!(
                !String::from_utf8_lossy(&out).contains(&k[..4]),
                "a prefix of the key went out before the rest came: cut {cut}"
            );
            out.extend(r.redact(&log.as_bytes()[cut..]));
            out.extend(r.finish());
            assert_eq!(String::from_utf8(out).unwrap(), want, "cut at {cut}");
        }
        // three chunks, the key's middle alone in the second
        let mut r = Redactor::new(&[secret(&k)]);
        let (a, b) = (log.find(&k).unwrap() + 2, log.find(&k).unwrap() + 6);
        let mut out = r.redact(&log.as_bytes()[..a]);
        out.extend(r.redact(&log.as_bytes()[a..b]));
        out.extend(r.redact(&log.as_bytes()[b..]));
        out.extend(r.finish());
        assert_eq!(String::from_utf8(out).unwrap(), want);
        // a key added mid-stream is masked from then on
        let mut r = Redactor::default();
        let first = r.redact(b"nothing yet\n");
        assert_eq!(first, b"nothing yet\n");
        r.add(&secret(&k));
        let mut out = r.redact(log.as_bytes());
        out.extend(r.finish());
        assert_eq!(String::from_utf8(out).unwrap(), want);
    }

    // [D] pure: the heuristic raises a notice on a line that looks like a secret and never masks it; a digest or a
    // commit id is no secret to it and passes untouched
    #[test]
    fn the_heuristic_never_redacts_a_digest() {
        let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let commit = "9aafed7a5d21a39d3b13ae1c88ba039cdc0b4d5a";
        // high entropy, mixed classes: what the heuristic flags (made here, split)
        let flagged = format!("{}{}", "Zq8vR2kLm9Xw4Tb7Np3Hs6Jd1Fg5Yc0", "Ae2Uo8Ii4Kk");
        let log = format!("sha256 {digest}\ncommit {commit}\nset {flagged}\nok\n");
        // the redactor holds an unrelated key: nothing of the log is its
        let mut r = Redactor::new(&[secret(&key())]);
        let mut out = r.redact(log.as_bytes());
        out.extend(r.finish());
        assert_eq!(String::from_utf8(out).unwrap(), log, "nothing is masked");
        assert_eq!(
            notices(log.as_bytes()),
            vec!["this log may hold a secret at line 3".to_string()]
        );
        assert!(notices(format!("{digest}\n{commit}\n").as_bytes()).is_empty());
    }
}
