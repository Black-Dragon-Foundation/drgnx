//! The key socket's request and answers (docs/develop/sleipnir.md, "Keys"), shared by the job helper on a runner
//! (`helper::keys`) and the hub's key socket for a keyed job on its own machine. Std only, on every target.
//!
//! `drgnx-key` sends one line, `get NAME`; the answer is `ok LEN\n` and the value's bytes, `no WHY\n`, or `timeout\n`
//! when the key hasn't come within [`KEY_WAIT`] (`drgnx-key` then exits [`NOT_DELIVERED`], which the job's result reads
//! as `infra: key not delivered`).

use std::time::Duration;

/// How long a request waits for its key.
pub const KEY_WAIT: Duration = Duration::from_secs(60);
/// `drgnx-key`'s exit status when its key never came.
pub const NOT_DELIVERED: i32 = 75;
/// The largest key value taken.
pub const MAX_KEY: usize = 64 << 10;
/// The longest request line.
pub const MAX_LINE: u64 = 512;
/// The answer to a request whose key didn't come in time.
pub const TIMEOUT: &[u8] = b"timeout\n";

/// A key name: what the job spec lists and `drgnx-key` asks for (letters, digits, `_`, `-`, `.`; at most 128).
pub fn plain_name(n: &str) -> bool {
    !n.is_empty()
        && n.len() <= 128
        && n.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
}

/// The key a request line REQ (without its newline) asks for; none when it isn't `get NAME` with a plain name.
pub fn requested(req: &str) -> Option<&str> {
    req.strip_prefix("get ").filter(|n| plain_name(n))
}

/// The answer to a line that isn't `get NAME`.
pub fn not_a_request() -> Vec<u8> {
    b"no not `get NAME`\n".to_vec()
}

/// The answer to a request for NAME, which the job doesn't name.
pub fn not_listed(name: &str) -> Vec<u8> {
    format!("no the job doesn't name the key {name}\n").into_bytes()
}

/// The head of an answer that carries a value of LEN bytes.
pub fn ok_head(len: usize) -> String {
    format!("ok {len}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] pure: only `get NAME` with a plain name is a request.
    #[test]
    fn only_get_with_a_plain_name_is_a_request() {
        assert_eq!(requested("get TOKEN"), Some("TOKEN"));
        assert_eq!(requested("get a.b-c_1"), Some("a.b-c_1"));
        for bad in ["get ", "get A B", "get ../x", "put TOKEN", "TOKEN", ""] {
            assert_eq!(requested(bad), None, "{bad:?}");
        }
        assert!(!plain_name(&"a".repeat(129)));
    }
}
