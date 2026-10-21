//! The rules that refuse a spec (Task 2). `validate` is the only way to make a [`ValidSpec`] outside tests.

#[cfg(doc)]
use crate::spec::ValidSpec;

/// Proof that a spec passed validation. Its field is private to this module, so only this module can make one, and
/// [`ValidSpec`]'s constructor takes one: no other module of the crate can make a `ValidSpec` (tests use
/// `ValidSpec::assume_valid`).
pub(crate) struct Checked(());

#[cfg(test)]
impl Checked {
    pub(crate) fn for_tests() -> Checked {
        Checked(())
    }
}
