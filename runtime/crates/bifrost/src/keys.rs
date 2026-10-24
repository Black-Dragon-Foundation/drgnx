//! Provider keys, in memory only (design §5.6, §6.2 rule 2).
//!
//! [`Keys`] has no `Debug`, `Display`, `Clone` or `Serialize`: a key can reach a log, a file or the wire only through
//! [`secrecy::ExposeSecret`], which the gateway calls in one place, building the upstream request's sensitive header
//! (`rewrite::headers`). Each [`SecretString`] is zeroed when it is dropped or replaced.

use std::collections::BTreeMap;

use secrecy::SecretString;

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

    /// The ids among `ids` with no key held, in their order.
    pub fn missing(&self, ids: &[&str]) -> Vec<String> {
        ids.iter()
            .filter(|id| !self.0.contains_key(**id))
            .map(|id| (*id).to_owned())
            .collect()
    }
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
