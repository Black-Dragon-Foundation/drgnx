//! The URL rule (contract Task 14) and the gateway's provider-base rule.  Task 1 fills the bodies and [`Url`]'s fields;
//! the signatures are fixed at Task 0.

/// A URL that passed [`check`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {}

/// Why a URL was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UrlRefusal {
    /// Any `NAME::` form.
    Transport,
    /// A scheme not in the allowed list (`user@host:path` counts as `ssh`, a local absolute path as `file`).
    Scheme,
    /// A control character, a leading `-`, userinfo in an http(s) URL, or no host.
    Malformed,
}

/// A provider's base URL: `https`, or `http` for any host; `clear_text` is `http` off loopback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderBase {
    pub url: Url,
    pub clear_text: bool,
}

/// URL against the allowed SCHEMES.
pub fn check(url: &str, schemes: &[&str]) -> Result<Url, UrlRefusal> {
    let _ = (url, schemes);
    todo!("Task 1")
}

/// The gateway's rule for a provider's base URL.
pub fn provider_base(url: &str) -> Result<ProviderBase, UrlRefusal> {
    let _ = url;
    todo!("Task 1")
}
