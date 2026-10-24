//! The one list of secret patterns (Urdr Task 9; storage §8.3): agent writes that look like a credential are refused
//! ("looks like a secret; do not store credentials"). Pure Rust, on the Android clippy list.
//!
//! The rules, tried in this order; [`looks_like_secret`] answers the first one's name:
//! - `private-key`: `-----BEGIN [A-Z ]*PRIVATE KEY-----`;
//! - `aws-key-id`: `AKIA` and 16 of `[0-9A-Z]`;
//! - `key-prefix`: a token starting `sk-` (also `sk-ant-`, `sk-or-`), `ghp_`, `gho_`, `github_pat_`, `glpat-`,
//!   `xoxa-`, `xoxb-` or `xoxp-`, with at least 16 more characters, a digit or a capital among them (so prose such
//!   as an `sk-learn-…` name is not a key);
//! - `assignment`: `password`, `passwd`, `secret`, `token`, `api_key`, `api-key` or `apikey` (any case), then `=` or
//!   `:` and a value of at least 8 non-space characters;
//! - `high-entropy`: a token of at least 40 characters with three of the classes lower, upper, digit and `+_-`, and
//!   Shannon entropy of at least 4.5 bits per character; 40- and 64-hex strings (commit and blob ids) are not.
//!
//! A token is a run of `[A-Za-z0-9+_-]`: anything else splits, so a path or a URL is several short tokens.

/// The name of the first rule TEXT matches, or `None`.
pub fn looks_like_secret(text: &str) -> Option<&'static str> {
    if private_key(text) {
        Some("private-key")
    } else if aws_key_id(text) {
        Some("aws-key-id")
    } else if tokens(text).any(key_prefix) {
        Some("key-prefix")
    } else if assignment(text) {
        Some("assignment")
    } else if tokens(text).any(high_entropy) {
        Some("high-entropy")
    } else {
        None
    }
}

const KEY_PREFIXES: &[&str] = &[
    "sk-",
    "sk-ant-",
    "sk-or-",
    "ghp_",
    "gho_",
    "github_pat_",
    "glpat-",
    "xoxa-",
    "xoxb-",
    "xoxp-",
];

/// Characters a key carries after its prefix, at least.
const MIN_AFTER_PREFIX: usize = 16;

const KEYWORDS: &[&str] = &[
    "password", "passwd", "secret", "token", "api_key", "api-key", "apikey",
];

/// An assigned value this long or longer is a secret.
const MIN_VALUE: usize = 8;

const MIN_TOKEN: usize = 40;

const MIN_BITS: f64 = 4.5;

fn token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '_' | '-')
}

fn tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !token_char(c))
        .filter(|t| !t.is_empty())
}

fn private_key(text: &str) -> bool {
    text.match_indices("-----BEGIN ").any(|(at, m)| {
        let rest = &text[at + m.len()..];
        let run = rest
            .find(|c: char| !(c.is_ascii_uppercase() || c == ' '))
            .unwrap_or(rest.len());
        rest[..run].ends_with("PRIVATE KEY") && rest[run..].starts_with("-----")
    })
}

fn aws_key_id(text: &str) -> bool {
    text.match_indices("AKIA").any(|(at, m)| {
        let rest = &text.as_bytes()[at + m.len()..];
        rest.len() >= 16
            && rest[..16]
                .iter()
                .all(|b| b.is_ascii_digit() || b.is_ascii_uppercase())
    })
}

fn key_prefix(token: &str) -> bool {
    KEY_PREFIXES.iter().any(|prefix| {
        token.strip_prefix(prefix).is_some_and(|rest| {
            rest.len() >= MIN_AFTER_PREFIX
                && rest
                    .chars()
                    .any(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
        })
    })
}

fn assignment(text: &str) -> bool {
    // ASCII lowercasing keeps every byte offset, so LOWER's offsets index TEXT.
    let lower = text.to_ascii_lowercase();
    KEYWORDS.iter().any(|keyword| {
        lower
            .match_indices(keyword)
            .any(|(at, _)| value_follows(&text[at + keyword.len()..]))
    })
}

/// Whether REST (what follows a keyword) is `= value` or `: value`, the value long enough. A closing quote after the
/// keyword (`"password": …`) and quotes, commas and semicolons around the value are skipped.
fn value_follows(rest: &str) -> bool {
    let rest = rest.strip_prefix(['"', '\'']).unwrap_or(rest);
    let rest = rest.trim_start_matches([' ', '\t']);
    let Some(rest) = rest.strip_prefix(['=', ':']) else {
        return false;
    };
    let value = rest
        .trim_start_matches([' ', '\t'])
        .split(char::is_whitespace)
        .next()
        .unwrap_or("")
        .trim_matches(['"', '\'', ',', ';']);
    value.chars().count() >= MIN_VALUE
}

fn high_entropy(token: &str) -> bool {
    if token.len() < MIN_TOKEN {
        return false;
    }
    if (token.len() == 40 || token.len() == 64) && token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return false;
    }
    let classes = [
        token.bytes().any(|b| b.is_ascii_lowercase()),
        token.bytes().any(|b| b.is_ascii_uppercase()),
        token.bytes().any(|b| b.is_ascii_digit()),
        token.bytes().any(|b| matches!(b, b'+' | b'_' | b'-')),
    ];
    classes.iter().filter(|&&c| c).count() >= 3 && entropy(token) >= MIN_BITS
}

/// Shannon entropy in bits per character of an ASCII TOKEN.
fn entropy(token: &str) -> f64 {
    let mut counts = [0u32; 128];
    for b in token.bytes() {
        counts[usize::from(b & 0x7f)] += 1;
    }
    let n = token.len() as f64;
    counts
        .iter()
        .filter(|&&c| c > 0)
        .map(|&c| {
            let p = f64::from(c) / n;
            -p * p.log2()
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use serde_json::Value;

    use super::*;

    /// The shared table; a case's text is a string or parts joined (so this public repository's leak hook never
    /// sees a whole key).
    #[test]
    fn every_case_in_the_shared_table() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/secret-cases.json");
        let table: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut wrong = Vec::new();
        let cases = table["cases"].as_array().unwrap();
        for case in cases {
            let text = match &case["text"] {
                Value::String(s) => s.clone(),
                Value::Array(parts) => parts.iter().map(|p| p.as_str().unwrap()).collect(),
                other => panic!("text: {other}"),
            };
            let want = case["rule"].as_str();
            let got = looks_like_secret(&text);
            if got != want {
                wrong.push(format!("{}: want {want:?}, got {got:?}", case["name"]));
            }
        }
        assert!(cases.len() > 30);
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    }

    #[test]
    fn entropy_of_known_strings() {
        assert!(entropy("aaaa").abs() < 1e-9);
        assert!((entropy("abcd") - 2.0).abs() < 1e-9);
    }
}
