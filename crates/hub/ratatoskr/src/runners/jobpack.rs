//! Where a job pack comes from, and what its entries' artifact keys cover (the hub's side of `vordr::jobs`).
//!
//! - **Discovery.** An author's run reads `.drgnx/jobs.toml` from the frozen tree (the user's work as it is); a gate
//!   reads it from the base commit, so a branch cannot loosen its own gate. Then the user's overlay (the project
//!   setting `jobs-overlay`, a folder with its own `jobs.toml`) is merged over it: an overlay entry adds or replaces.
//! - **The overlay stays home.** A job whose entry comes from the overlay reads files that exist only on the user's
//!   machine: it places only on a `mine` runner ([`overlay_entry`], `Placement::pack_overlay`), and those files are
//!   never mirrored to a cloud or shared runner.
//! - **Keys.** [`key_inputs`] assembles an entry's [`forseti::KeyInputs`] from the frozen tree's listing, the resolved
//!   entry, its toolchain digest, the keys it uses and the overlay's recipe files.

use std::collections::BTreeSet;

use forseti::{ArtifactKey, KeyInputs, Role};
use sleipnir::proto::ManifestEntry;
use vordr::jobs::{self, JobPack};

/// Where the texts of a pack are read from: the frozen tree, the base commit and the overlay folder.
pub trait Source {
    /// `.drgnx/jobs.toml` of the frozen tree (the author's), or none when the tree has none.
    fn tree(&self) -> villa::Result<Option<String>>;
    /// The same file at the gate's base commit.
    fn base(&self) -> villa::Result<Option<String>>;
    /// The overlay folder's `jobs.toml`, or none when the project has no `jobs-overlay`.
    fn overlay(&self) -> villa::Result<Option<String>>;
}

/// The pack a job of ROLE runs under, and the names of the entries that came from the overlay.
#[derive(Clone, Debug)]
pub struct Found {
    pub pack: JobPack,
    pub from_overlay: BTreeSet<String>,
}

/// The pack for ROLE from SRC: none when the repo has no pack file (and no overlay).
pub fn discover(role: Role, src: &dyn Source) -> villa::Result<Option<Found>> {
    let text = match role {
        Role::Author => src.tree()?,
        Role::Gate => src.base()?,
    };
    let repo = text.map(|t| load(&t, jobs::FILE)).transpose()?;
    let overlay = src
        .overlay()?
        .map(|t| load(&t, "jobs-overlay/jobs.toml"))
        .transpose()?;
    Ok(match (repo, overlay) {
        (None, None) => None,
        (Some(pack), None) => Some(Found {
            pack,
            from_overlay: BTreeSet::new(),
        }),
        (repo, Some(o)) => {
            let mut from_overlay: BTreeSet<String> = o
                .stages
                .iter()
                .chain(&o.artifacts)
                .map(|e| e.name.clone())
                .collect();
            let pack = match repo {
                Some(r) => jobs::merge_overlay(r, o),
                None => o,
            };
            from_overlay.retain(|n| pack.entry(n).is_some());
            Some(Found { pack, from_overlay })
        }
    })
}

fn load(text: &str, file: &str) -> villa::Result<JobPack> {
    jobs::load(text, file).map_err(|errs| {
        villa::Error::invalid(
            errs.iter()
                .map(|e| format!("{}:{}: {}", e.file, e.line, e.msg))
                .collect::<Vec<_>>()
                .join("; "),
        )
    })
}

/// Whether the entry NAME reads overlay files: it came from the overlay, or it uses an artifact that did.
pub fn overlay_entry(found: &Found, name: &str) -> bool {
    if found.from_overlay.contains(name) {
        return true;
    }
    found.pack.entry(name).is_some_and(|e| {
        e.uses
            .iter()
            .any(|u| found.from_overlay.contains(&u.artifact))
    })
}

/// The files of LISTING (`(path, blob id)`) that match any of the entry's `inputs` globs and none of its
/// `key-ignore` globs: what the key covers of the tree.
pub fn blobs_matching(
    listing: &[(String, String)],
    inputs: &[String],
    ignore: &[String],
) -> Vec<(String, String)> {
    listing
        .iter()
        .filter(|(p, _)| inputs.iter().any(|g| forseti::artifact::glob_match(g, p)))
        .filter(|(p, _)| !ignore.iter().any(|g| forseti::artifact::glob_match(g, p)))
        .cloned()
        .collect()
}

/// The key inputs of the entry NAME of FOUND: its tree files from LISTING, its resolved form, TOOLCHAIN's digest, the
/// keys of the artifacts it USED, and the pack overlay files it reads (OVERLAY: the frozen manifest of the folder).
pub fn key_inputs(
    found: &Found,
    name: &str,
    listing: &[(String, String)],
    toolchain: &str,
    used: Vec<ArtifactKey>,
    overlay: &[ManifestEntry],
) -> villa::Result<KeyInputs> {
    let entry = found.pack.entry(name).ok_or_else(|| {
        villa::Error::not_found(format!("the pack has no stage or artifact `{name}`"))
    })?;
    let recipe_files = if overlay_entry(found, name) {
        overlay
            .iter()
            .filter_map(|m| match m {
                ManifestEntry::File { path, sha256, .. } => Some((
                    String::from_utf8_lossy(path).into_owned(),
                    sha256
                        .0
                        .iter()
                        .map(|b| format!("{b:02x}"))
                        .collect::<String>(),
                )),
                ManifestEntry::Deleted { .. } => None,
            })
            .collect()
    } else {
        vec![]
    };
    Ok(KeyInputs {
        entry: found.pack.resolve(name)?,
        toolchain: toolchain.to_string(),
        blobs: blobs_matching(listing, &entry.inputs, &entry.key_ignore),
        overlay: vec![],
        used,
        inputs: vec![],
        recipe_files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const D: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn pack(extra: &str) -> String {
        format!(
            r#"jobs = 1
project = "p"

[toolchains.gcc]
image = "registry.example/fedora:45@sha256:{D}"

[[artifact]]
name = "build"
kind = "command"
toolchain = "gcc"
inputs = ["src/**"]
steps = [["make"]]
keep = {{ from = "{{build}}", paths = ["out"] }}
{extra}
"#
        )
    }

    struct Fixed {
        tree: Option<String>,
        base: Option<String>,
        overlay: Option<String>,
    }

    impl Source for Fixed {
        fn tree(&self) -> villa::Result<Option<String>> {
            Ok(self.tree.clone())
        }
        fn base(&self) -> villa::Result<Option<String>> {
            Ok(self.base.clone())
        }
        fn overlay(&self) -> villa::Result<Option<String>> {
            Ok(self.overlay.clone())
        }
    }

    // [D] pure: an author reads the tree's pack, a gate the base's, so a branch cannot loosen its own gate
    #[test]
    fn a_gate_reads_the_pack_from_the_base() {
        let src = Fixed {
            tree: Some(pack("")),
            base: Some(pack("").replace("[\"make\"]", "[\"make\", \"-j1\"]")),
            overlay: None,
        };
        let cmd = |f: Found| format!("{:?}", f.pack.resolve("build").unwrap());
        let author = cmd(discover(Role::Author, &src).unwrap().unwrap());
        let gate = cmd(discover(Role::Gate, &src).unwrap().unwrap());
        assert!(
            author.contains("make") && !author.contains("-j1"),
            "{author}"
        );
        assert!(gate.contains("-j1"), "{gate}");
        // a base without a pack file: a gate has none, an author still has its tree's
        let src = Fixed { base: None, ..src };
        assert!(discover(Role::Gate, &src).unwrap().is_none());
        assert!(discover(Role::Author, &src).unwrap().is_some());
    }

    // [D] pure: the overlay's entries are marked, and a job of one (or one that uses one) stays on `mine` runners
    #[test]
    fn an_overlay_job_never_places_on_my_cloud_or_shared() {
        let overlay = format!(
            r#"jobs = 1
project = "p"

[[artifact]]
name = "local-build"
kind = "command"
toolchain = "gcc"
inputs = ["src/**"]
steps = [["make", "local"]]
keep = {{ from = "{{build}}", paths = ["out"] }}

[toolchains.gcc]
image = "registry.example/fedora:45@sha256:{D}"
"#
        );
        let src = Fixed {
            tree: Some(pack("")),
            base: None,
            overlay: Some(overlay),
        };
        let found = discover(Role::Author, &src).unwrap().unwrap();
        assert!(overlay_entry(&found, "local-build"));
        assert!(
            !overlay_entry(&found, "build"),
            "a repo entry stays placeable"
        );
    }

    // [D] pure: a file's path and content (the sha256) of the overlay change the key of an entry that reads it
    #[test]
    fn overlay_files_enter_the_key() {
        let src = Fixed {
            tree: None,
            base: None,
            overlay: Some(pack("")),
        };
        let found = discover(Role::Author, &src).unwrap().unwrap();
        let file = |sha: u8| {
            vec![ManifestEntry::File {
                path: b"recipe.sh".to_vec(),
                mode: 0o644,
                sha256: sleipnir::proto::Sha256([sha; 32]),
                size: 1,
            }]
        };
        let key = |o: &[ManifestEntry]| {
            forseti::artifact_key(&key_inputs(&found, "build", &[], "d", vec![], o).unwrap())
        };
        assert_ne!(key(&file(1)), key(&file(2)));
        assert_ne!(key(&file(1)), key(&[]));
    }

    // [D] pure: the entry's inputs pick the tree's files; key-ignore drops some
    #[test]
    fn blobs_follow_inputs_and_key_ignore() {
        let listing: Vec<(String, String)> =
            [("src/a.c", "1"), ("src/a.md", "2"), ("doc/x.md", "3")]
                .iter()
                .map(|(a, b)| (a.to_string(), b.to_string()))
                .collect();
        let got = blobs_matching(&listing, &["src/**".into()], &["**/*.md".into()]);
        assert_eq!(got, vec![("src/a.c".to_string(), "1".to_string())]);
    }

    // [D] pure: the hub's parser list equals the executor's, so a pack the hub accepts is one a runner can read
    #[test]
    fn the_pack_parsers_equal_the_executors() {
        let mut hub: Vec<&str> = jobs::PARSERS.to_vec();
        let mut exec: Vec<&str> = sleipnir::linux::parse::PARSERS.to_vec();
        hub.sort();
        exec.sort();
        assert_eq!(hub, exec);
    }

    // [D] pure: a pack with an error is refused with its file and line
    #[test]
    fn a_bad_pack_is_refused_with_its_line() {
        let src = Fixed {
            tree: Some("jobs = 1\nproject = \"p\"\nbogus = 1\n".into()),
            base: None,
            overlay: None,
        };
        let err = discover(Role::Author, &src).unwrap_err().to_string();
        assert!(err.contains(".drgnx/jobs.toml:3"), "{err}");
    }
}
