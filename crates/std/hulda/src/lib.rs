//! hulda (*hulða*, concealment): secrets that never print (docs/develop/standards/data-hygiene.md).
//!
//! A token, key, password or credential lives in a [`Secret`]: its `Debug` and `Display` print [`REDACTED`], so an
//! error, a log line or a panic message that formats it shows nothing of it. The value is reached only by
//! [`Secret::expose`], named so a reader sees where it leaves. [`Redact`] is the redacted text of a type that is not
//! wholly secret (annall's `redact` puts it in a log field). The scanner's rule `secret-has-redact` rejects a type named
//! `…Token`, `…Secret`, `…Key`, `…Password` or `…Credential` that derives `Debug` unless every field is a `Secret`.

use std::fmt;

/// What a secret prints as.
pub const REDACTED: &str = "‹redacted›";

/// A value's form for a log or a message, with its secret parts left out.
pub trait Redact {
    fn redacted(&self) -> String;
}

/// A secret value: it prints as [`REDACTED`] and is reached only through [`Secret::expose`].
#[derive(Clone, PartialEq, Eq)]
pub struct Secret<T>(T);

impl<T> Secret<T> {
    pub fn new(value: T) -> Secret<T> {
        Secret(value)
    }

    /// The value itself: for the one place it is sent or checked, never to format.
    pub fn expose(&self) -> &T {
        &self.0
    }
}

impl<T> From<T> for Secret<T> {
    fn from(value: T) -> Secret<T> {
        Secret(value)
    }
}

impl<T> fmt::Debug for Secret<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(REDACTED)
    }
}

impl<T> fmt::Display for Secret<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(REDACTED)
    }
}

impl<T> Redact for Secret<T> {
    fn redacted(&self) -> String {
        REDACTED.to_string()
    }
}
