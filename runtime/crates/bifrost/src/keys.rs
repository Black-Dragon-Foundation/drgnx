//! Provider keys, in memory only (design §5.6, §6.2 rule 2).
//!
//! [`Keys`] has no `Debug`, `Display`, `Clone` or `Serialize`: a key can reach a log, a file or the wire only through
//! [`secrecy::ExposeSecret`], which the gateway calls in one place, building the upstream request's sensitive header
//! (`rewrite::headers`), and [`Keys::scrub`] here, which only compares. Each [`SecretString`] is zeroed when it is
//! dropped or replaced.

use std::borrow::Cow;
use std::collections::BTreeMap;

use secrecy::{ExposeSecret, SecretString};

/// Provider id → its key.
#[derive(Default)]
pub struct Keys(BTreeMap<String, SecretString>);

impl Keys {
    pub fn new() -> Self {
        Self::default()
    }

    /// Hold `key` for provider `id`, replacing (and so zeroing) the one held before.
    pub fn set(&mut self, id: impl Into<String>, key: SecretString) {
        self.0.insert(id.into(), key);
    }

    /// [`Keys::set`] for each pair.
    pub fn set_many(&mut self, keys: impl IntoIterator<Item = (String, SecretString)>) {
        for (id, key) in keys {
            self.set(id, key);
        }
    }

    pub fn get(&self, id: &str) -> Option<&SecretString> {
        self.0.get(id)
    }

    /// DATA with every held key replaced by `$SECRET` (a recording's scrub): the keys never leave this module.
    pub fn scrub<'a>(&self, data: &'a [u8]) -> Cow<'a, [u8]> {
        let mut out = Cow::Borrowed(data);
        for key in self.0.values() {
            let key = key.expose_secret().as_bytes();
            if key.is_empty() || !contains(&out, key) {
                continue;
            }
            let mut next = Vec::with_capacity(out.len());
            let mut rest: &[u8] = &out;
            while let Some(at) = find(rest, key) {
                next.extend_from_slice(&rest[..at]);
                next.extend_from_slice(b"$SECRET");
                rest = &rest[at + key.len()..];
            }
            next.extend_from_slice(rest);
            out = Cow::Owned(next);
        }
        out
    }

    /// The ids among `ids` with no key held, in their order.
    pub fn missing(&self, ids: &[&str]) -> Vec<String> {
        ids.iter()
            .filter(|id| !self.0.contains_key(**id))
            .map(|id| (*id).to_owned())
            .collect()
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    find(hay, needle).is_some()
}

#[cfg(test)]
mod tests {
    use secrecy::ExposeSecret;

    use super::*;

    #[test]
    fn set_many_then_missing_names_the_rest() {
        let mut keys = Keys::new();
        keys.set("openrouter", SecretString::from("sk-old"));
        keys.set_many([
            ("openrouter".to_owned(), SecretString::from("sk-new")),
            ("anthropic".to_owned(), SecretString::from("sk-ant")),
        ]);
        assert_eq!(keys.get("openrouter").unwrap().expose_secret(), "sk-new");
        assert_eq!(keys.get("anthropic").unwrap().expose_secret(), "sk-ant");
        assert!(keys.get("ollama").is_none());
        assert_eq!(
            keys.missing(&["ollama", "anthropic", "tei"]),
            vec!["ollama".to_owned(), "tei".to_owned()]
        );
    }
}
