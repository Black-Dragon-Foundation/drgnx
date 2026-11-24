//! Artifacts on a runner (docs/develop/sleipnir.md, "Artifacts"): what a pack's `artifact` entry builds, kept on the
//! runner's disk and used read-only by the jobs that name it.
//!
//! - [`store`]: the folder of committed artifacts. A build writes `<key>.part` and commits by a rename, so a half-made
//!   artifact is never visible; a committed one is read-only and is an `Artifact` item of the disk register, which the
//!   guard keeps while a job needs it ([`forseti::artifact::item_id`]).
//! - [`image`]: the `image` kind. The hub computes an image's key from the files its Containerfile reads, and decides
//!   whether the registry's image is pulled by digest or the runner builds it. Jobs run the image by ID, and only when
//!   its label names the key.
//! - [`command`]: the `command` kind. A container job runs the entry's steps in order; the first that fails stops the
//!   rest and nothing is committed; `{out}` is what is kept.
//! - [`expand`]: the placeholders (`{src}`, `{out}`, `{art:NAME}`, `{jobs}` …) of an argv or an environment, expanded on
//!   the runner, where the paths are.

pub mod command;
pub mod expand;
pub mod image;
pub mod store;

/// The label every artifact image carries, with the artifact's key as its value.
pub const LABEL: &str = "org.drgnx.artifact";

/// Where a `command` artifact's `{out}` appears inside its build container.
pub const OUT_INSIDE: &str = "/out";

/// Where a job sees the artifact it uses by the name NAME (`ro` uses): `{art:NAME}` expands to this.
pub fn art_inside(name: &str) -> String {
    format!("/art/{name}")
}

/// A key as the pack writes it: 64 lowercase hex digits.
pub fn key_ok(key: &str) -> bool {
    key.len() == 64
        && key
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// An artifact's name as a path word: letters, digits, `-`, `_` and `.`, not starting with `.` or `-`.
pub fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with(['.', '-'])
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}
