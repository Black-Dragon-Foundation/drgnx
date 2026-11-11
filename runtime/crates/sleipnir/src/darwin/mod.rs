//! The macOS side of a runner (a Mac with Apple silicon, in a standard account of its own): the machine probe and its
//! contract ([`probe`]). The parsers and the contract are pure and build everywhere, so Linux tests run them on
//! fixtures; reading the machine (`sysctl`, `sw_vers`, `brew`) is `target_os = "macos"` only.
//! `docs/develop/sleipnir.md`, "A Mac runner".

pub mod probe;
