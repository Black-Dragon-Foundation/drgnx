//! An artifact's key (docs/develop/forseti.md, "Artifact keys"): the SHA-256 of the whole resolved pack entry less its
//! scheduling-only fields, the toolchain image's identity, the input blobs, the keys of the artifacts it uses and the
//! overlay's recipe files. Pure.
//!
//! The entry ([`Canon`]) is what `vordr::jobs` resolves: the artifact's pack entry after the `defaults` merge, the
//! overlay merge and hub-side expansion, with the toolchain, every named cache inlined (under `toolchain` and
//! `caches`). Runner-side placeholders (`{jobs}`, `{build}`, `{key:NAME}` …) are literal text here: a key's value never
//! reaches it, only its name. A pack that differs from the base's in any field a build reads has another key, so a
//! tip pack can't mint a base key.
//!
//! One key is also CI's image tag when the artifact is an image: its inputs are the same files the image tag hashes.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::cachekey::Feed;

/// The key scheme, fed first: a new scheme never meets an old key.
pub const SCHEMA: &str = "artifact/3";

/// The fields that place, size or explain a job and never change what it builds: dropped at every table level before
/// the entry is fed. Everything else is in the key.
pub const SCHEDULING_ONLY: &[&str] = &[
    "mem",
    "cores",
    "unit-mib",
    "disk-gib",
    "timebox",
    "stall",
    "silent",
    "why",
    "light",
    "class",
    "lane",
    "weight",
    "machine",
    "retain",
    "budget-gib",
    "sharing",
];

/// Every field of a pack's stages, artifacts, toolchains and caches (their TOML names): what `vordr::jobs` accepts, and
/// what the key's property row walks to show each non-scheduling one changes the key.
pub const FIELDS: &[&str] = &[
    "name",
    "kind",
    "run",
    "steps",
    "toolchain",
    "host",
    "uses",
    "needs",
    "parser",
    "select",
    "expect",
    "list",
    "mem",
    "cores",
    "unit-mib",
    "timebox",
    "stall",
    "silent",
    "why",
    "disk-gib",
    "git",
    "features",
    "light",
    "class",
    "lane",
    "weight",
    "os",
    "machine",
    "writes",
    "outputs",
    "reports",
    "caches",
    "env",
    "selector-env",
    "missing-symbol",
    "in-tree",
    "inputs",
    "key-ignore",
    "keep",
    "retain",
    "dir",
    "image",
    "setup-image",
    "sharing",
    "budget-gib",
    "preset",
    "split",
    "image-digest",
    "path",
];

/// An artifact's key: 64 hex digits.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ArtifactKey(pub String);

/// A key is a content hash, never a secret: its Debug is the hex, written by hand (the scanner reads every `Key` type
/// as a secret that must not derive Debug).
impl std::fmt::Debug for ArtifactKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "ArtifactKey({})", self.0)
    }
}

/// A resolved pack entry as data (TOML's values: strings, integers, booleans, arrays, tables with their keys).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Canon {
    Str(String),
    Int(i64),
    Bool(bool),
    List(Vec<Canon>),
    /// A table: its keys with their values, in any order.
    Plist(Vec<(String, Canon)>),
}

impl Canon {
    /// The value under KEY of a table; none for anything else.
    pub fn get(&self, key: &str) -> Option<&Canon> {
        match self {
            Canon::Plist(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    fn feed(&self, f: &mut Feed) {
        match self {
            Canon::Str(s) => {
                f.0.update(*b"s");
                f.str(s);
            }
            Canon::Int(n) => {
                f.0.update(*b"i");
                f.0.update(n.to_le_bytes());
            }
            Canon::Bool(b) => f.0.update([b'b', u8::from(*b)]),
            Canon::List(l) => {
                f.0.update(*b"l");
                f.0.update((l.len() as u64).to_le_bytes());
                for x in l {
                    x.feed(f);
                }
            }
            Canon::Plist(kv) => {
                let mut kept: Vec<&(String, Canon)> = kv
                    .iter()
                    .filter(|(k, _)| !SCHEDULING_ONLY.contains(&k.as_str()))
                    .collect();
                kept.sort_by(|a, b| a.0.cmp(&b.0));
                f.0.update(*b"p");
                f.0.update((kept.len() as u64).to_le_bytes());
                for (k, v) in kept {
                    f.str(k);
                    v.feed(f);
                }
            }
        }
    }
}

/// Everything an artifact's key covers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyInputs {
    /// The resolved entry, the referenced toolchain and caches inlined.
    pub entry: Canon,
    /// The toolchain's identity: the image's platform digest, nothing else.
    pub toolchain: String,
    /// `(path, git blob id)` of the frozen tree's files that match the entry's `inputs`.
    pub blobs: Vec<(String, String)>,
    /// `(path, sha256)` of the overlay's (uncommitted) files that match; a deletion's hash is empty.
    pub overlay: Vec<(String, String)>,
    /// The keys of the artifacts it uses.
    pub used: Vec<ArtifactKey>,
    /// Always empty: git inputs are not built. The field stays so the key's shape does not change when they are.
    pub inputs: Vec<(String, String)>,
    /// `(path, sha256)` of the pack overlay's recipe files it reads.
    pub recipe_files: Vec<(String, String)>,
}

fn pairs(f: &mut Feed, v: &[(String, String)]) {
    let mut v: Vec<&(String, String)> = v.iter().collect();
    v.sort();
    f.0.update((v.len() as u64).to_le_bytes());
    for (a, b) in v {
        f.str(a);
        f.str(b);
    }
}

/// The key of K ([`SCHEMA`]): the order of K's lists and of a table's keys never matters; a list inside the entry
/// keeps its order (steps, argv).
pub fn artifact_key(k: &KeyInputs) -> ArtifactKey {
    let mut f = Feed(Sha256::new());
    f.str(SCHEMA);
    k.entry.feed(&mut f);
    f.str(&k.toolchain);
    pairs(&mut f, &k.blobs);
    pairs(&mut f, &k.overlay);
    let mut used: Vec<String> = k.used.iter().map(|u| u.0.clone()).collect();
    used.sort();
    f.list(&used);
    pairs(&mut f, &k.inputs);
    pairs(&mut f, &k.recipe_files);
    ArtifactKey(f.0.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Whether PATH (slash-separated, relative to the tree's top) is an input of GLOBS: it matches one pattern and no
/// `!`-pattern. Patterns are anchored at the top: `*` and `?` stay within one segment, `**` spans any number of
/// segments (none too).
pub fn inputs_match(globs: &[String], path: &str) -> bool {
    let mut hit = false;
    for g in globs {
        match g.strip_prefix('!') {
            Some(neg) if glob_match(neg, path) => return false,
            Some(_) => {}
            None => hit = hit || glob_match(g, path),
        }
    }
    hit
}

/// Whether PATTERN matches PATH (see [`inputs_match`]).
pub fn glob_match(pattern: &str, path: &str) -> bool {
    let p: Vec<&str> = pattern.split('/').collect();
    let s: Vec<&str> = path.split('/').collect();
    segments(&p, &s)
}

fn segments(p: &[&str], s: &[&str]) -> bool {
    match p.split_first() {
        None => s.is_empty(),
        Some((&"**", rest)) => (0..=s.len()).any(|i| segments(rest, &s[i..])),
        Some((first, rest)) => match s.split_first() {
            Some((seg, srest)) => {
                segment(first.as_bytes(), seg.as_bytes()) && segments(rest, srest)
            }
            None => false,
        },
    }
}

fn segment(p: &[u8], s: &[u8]) -> bool {
    match p.split_first() {
        None => s.is_empty(),
        Some((b'*', rest)) => (0..=s.len()).any(|i| segment(rest, &s[i..])),
        Some((b'?', rest)) => !s.is_empty() && segment(rest, &s[1..]),
        Some((c, rest)) => s.first() == Some(c) && segment(rest, &s[1..]),
    }
}

/// The disk register's id of artifact KEY of PROJECT built in ROLE: `artifact:<role>:<project>:<key>`. The runner
/// registers a committed artifact under it, and the hub's pins name it, so a key a queued or running job needs is never
/// evicted. The role and the project are in the id because the key is not (a gate's build and an author's of one key are
/// two folders, and so are two projects').
pub fn item_id(role: crate::Role, project: &str, key: &ArtifactKey) -> String {
    format!("artifact:{}:{project}:{}", role.name(), key.0)
}

/// The register ids a job of PROJECT that uses KEY keeps: both roles' (an author's job may be served from the gate's
/// build).
pub fn item_ids(project: &str, key: &ArtifactKey) -> [String; 2] {
    [
        item_id(crate::Role::Author, project, key),
        item_id(crate::Role::Gate, project, key),
    ]
}

/// What a toolchain is, for the keys that name it: the image's platform digest (`sha256:<64 hex>`), never the index's:
/// an index lists one manifest per platform, so its digest would change when another platform's image does. A bare 64
/// hex is taken as a platform digest; anything else is refused.
pub fn toolchain_identity(platform_digest: &str) -> villa::Result<String> {
    let hex = platform_digest
        .strip_prefix("sha256:")
        .unwrap_or(platform_digest);
    if hex.len() == 64
        && hex
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Ok(format!("sha256:{hex}"))
    } else {
        Err(villa::Error::invalid(format!(
            "a toolchain's identity is its image's platform digest (sha256:<64 hex>), not {platform_digest:?}"
        )))
    }
}

/// What an artifact job builds: the hub sets it in the job's [`crate::Derived`] when it makes the job for a pack's
/// artifact entry, and the runner builds it itself (an `image` with `podman build` or `pull`, a `command` in a container
/// job whose `{out}` it then commits).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactBuild {
    /// `image` or `command`.
    pub kind: String,
    pub key: ArtifactKey,
    /// The pack's name for it.
    pub name: String,
    /// A `command`'s steps, run in order inside the job's container; the first non-zero stops the rest and nothing is
    /// committed.
    #[serde(default)]
    pub steps: Vec<Vec<String>>,
    /// A `command`'s `keep`: only these paths of a folder are copied into `{out}`.
    #[serde(default)]
    pub keep: Option<Keep>,
    /// An `image`'s recipe.
    #[serde(default)]
    pub image: Option<ImageBuild>,
}

/// `keep = { from = DIR, paths = [GLOB…] }`: the folder `{out}` is made from, and the paths (globs, relative to `from`)
/// that are copied.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Keep {
    pub from: String,
    pub paths: Vec<String>,
}

/// An `image` artifact's recipe, and the hub's decision: with `digest` the registry has the image for this key and the
/// runner pulls it; without, the runner builds it from the tree.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageBuild {
    pub containerfile: String,
    pub context: String,
    /// The registry repository the image lives in (`host/name`), checked against the project's allow-list.
    pub repo: String,
    #[serde(default)]
    pub digest: Option<String>,
    /// The registry's index digest that lists `digest` for the platforms (an allow-list entry of the index allows it).
    #[serde(default)]
    pub index: Option<String>,
    /// The repositories the project's image allow-list holds: a pull is checked against them on the runner too.
    #[serde(default)]
    pub allow: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn s(x: &str) -> Canon {
        Canon::Str(x.into())
    }

    fn pl(kv: &[(&str, Canon)]) -> Canon {
        Canon::Plist(kv.iter().map(|(k, v)| (k.to_string(), v.clone())).collect())
    }

    /// An artifact entry with every field set, and a toolchain and a cache inlined, each with every field.
    fn full(change: Option<(&str, &str)>) -> Canon {
        // CHANGE: (where, field): where is "top", "toolchain" or "cache"
        let val = |at: &str, f: &str| {
            if change == Some((at, f)) {
                s("changed")
            } else {
                s(&format!("v{f}"))
            }
        };
        let all = |at: &str| -> Vec<(String, Canon)> {
            FIELDS
                .iter()
                .filter(|f| !matches!(**f, "toolchain" | "caches"))
                .map(|f| (f.to_string(), val(at, f)))
                .collect()
        };
        let mut top = all("top");
        top.push(("toolchain".into(), Canon::Plist(all("toolchain"))));
        top.push((
            "caches".into(),
            Canon::List(vec![Canon::Plist(all("cache"))]),
        ));
        Canon::Plist(top)
    }

    fn key_of(entry: Canon) -> ArtifactKey {
        artifact_key(&KeyInputs {
            entry,
            toolchain: "sha256:t".into(),
            blobs: vec![("src/a.c".into(), "b1".into())],
            overlay: vec![],
            used: vec![],
            inputs: vec![],
            recipe_files: vec![],
        })
    }

    #[test]
    fn every_non_scheduling_field_changes_the_key() {
        // [D] pure: over the schema's fields, at the entry's top level and in a referenced toolchain and cache
        let base = key_of(full(None));
        for at in ["top", "toolchain", "cache"] {
            for f in FIELDS
                .iter()
                .filter(|f| !matches!(**f, "toolchain" | "caches"))
            {
                let k = key_of(full(Some((at, f))));
                if SCHEDULING_ONLY.contains(f) {
                    assert_eq!(k, base, "{at} {f} is scheduling-only");
                } else {
                    assert_ne!(k, base, "{at} {f} must change the key");
                }
            }
        }
    }

    #[test]
    fn scheduling_only_fields_keep_the_key() {
        // [D] pure: each of the 16 changed (or added) at the top and inside a cache: the same key
        assert_eq!(SCHEDULING_ONLY.len(), 16);
        let entry = |extra: Option<(&str, Canon)>| {
            let mut kv = vec![("steps".to_string(), Canon::List(vec![s("make")]))];
            let mut cache = vec![("env".to_string(), s("A=1"))];
            if let Some((k, v)) = extra {
                kv.push((k.to_string(), v.clone()));
                cache.push((k.to_string(), v));
            }
            kv.push(("caches".into(), Canon::List(vec![Canon::Plist(cache)])));
            Canon::Plist(kv)
        };
        let base = key_of(entry(None));
        for f in SCHEDULING_ONLY {
            assert_eq!(key_of(entry(Some((f, Canon::Int(1))))), base, "{f}");
            assert_eq!(key_of(entry(Some((f, Canon::Int(2))))), base, "{f}");
        }
    }

    #[test]
    fn order_of_inputs_does_not_matter() {
        // [D] pure: the lists of KeyInputs and a table's key order are sets; a list in the entry keeps its order
        let a = KeyInputs {
            entry: pl(&[("env", s("A=1")), ("kind", s("command"))]),
            toolchain: "t".into(),
            blobs: vec![("a".into(), "1".into()), ("b".into(), "2".into())],
            overlay: vec![("x".into(), "3".into()), ("y".into(), "".into())],
            used: vec![ArtifactKey("k1".into()), ArtifactKey("k2".into())],
            inputs: vec![],
            recipe_files: vec![("r1".into(), "h1".into()), ("r2".into(), "h2".into())],
        };
        let mut b = a.clone();
        b.entry = pl(&[("kind", s("command")), ("env", s("A=1"))]);
        b.blobs.reverse();
        b.overlay.reverse();
        b.used.reverse();
        b.recipe_files.reverse();
        assert_eq!(artifact_key(&a), artifact_key(&b));
        let mut c = a.clone();
        c.entry = pl(&[("steps", Canon::List(vec![s("a"), s("b")]))]);
        let mut d = a.clone();
        d.entry = pl(&[("steps", Canon::List(vec![s("b"), s("a")]))]);
        assert_ne!(artifact_key(&c), artifact_key(&d));
    }

    proptest! {
        /// [D] pure, generated trees: the key changes exactly when a file the `inputs` globs match changes
        #[test]
        fn a_key_changes_exactly_when_a_listed_input_changes(
            files in prop::collection::btree_map("(src|test|doc)/[a-c]{1,2}\\.(c|h|md)", "[0-9a-f]{4}", 1..12),
            pick in 0usize..12,
            blob in "[0-9a-f]{5}",
        ) {
            let globs = vec!["src/**".to_string(), "!src/**/*.md".to_string(), "test/*.h".to_string()];
            let listed = |tree: &std::collections::BTreeMap<String, String>| -> Vec<(String, String)> {
                tree.iter().filter(|(p, _)| inputs_match(&globs, p)).map(|(p, b)| (p.clone(), b.clone())).collect()
            };
            let key = |tree: &std::collections::BTreeMap<String, String>| artifact_key(&KeyInputs {
                entry: pl(&[("inputs", Canon::List(globs.iter().map(|g| s(g)).collect()))]),
                toolchain: "t".into(),
                blobs: listed(tree),
                overlay: vec![], used: vec![], inputs: vec![], recipe_files: vec![],
            });
            let path = files.keys().nth(pick % files.len()).unwrap().clone();
            let mut changed = files.clone();
            changed.insert(path.clone(), blob);
            let same = key(&files) == key(&changed);
            prop_assert_eq!(same, !inputs_match(&globs, &path) || files[&path] == changed[&path]);
        }
    }

    #[test]
    fn a_tip_pack_cannot_mint_a_base_key() {
        // [D] pure: two packs that differ only in an artifact's `env`: two keys
        let base = pl(&[
            ("steps", Canon::List(vec![s("make")])),
            ("env", Canon::List(vec![s("CC=gcc")])),
        ]);
        let tip = pl(&[
            ("steps", Canon::List(vec![s("make")])),
            ("env", Canon::List(vec![s("CC=evil")])),
        ]);
        assert_ne!(key_of(base), key_of(tip));
    }

    #[test]
    fn a_key_value_never_enters_the_key() {
        // [D] pure: `{key:TOKEN}` stays literal text in the entry (the runner fills it, never the hub), so the key is the
        // same whatever value the key holds; only its name is in the key
        let entry = |name: &str| {
            pl(&[(
                "env",
                Canon::List(vec![s(&format!("TOKEN={{key:{name}}}"))]),
            )])
        };
        assert_eq!(key_of(entry("TOKEN")), key_of(entry("TOKEN")));
        assert_ne!(key_of(entry("TOKEN")), key_of(entry("OTHER")));
        // an entry where a value was put in instead is another key: the value would be in it
        assert_ne!(
            key_of(entry("TOKEN")),
            key_of(pl(&[("env", Canon::List(vec![s("TOKEN=secret")]))]))
        );
    }

    #[test]
    fn a_boolean_and_its_string_are_two_keys() {
        // [D] pure: `host = true` and `host = "true"` never feed the same bytes
        assert_ne!(
            key_of(pl(&[("in-tree", Canon::Bool(true))])),
            key_of(pl(&[("in-tree", s("true"))]))
        );
    }

    #[test]
    fn globs_are_anchored_and_segmented() {
        // [D] pure
        assert!(glob_match("src/**", "src/a/b.c"));
        assert!(glob_match("**/*.c", "a.c"));
        assert!(glob_match("src/*.c", "src/a.c"));
        assert!(!glob_match("src/*.c", "src/x/a.c"));
        assert!(!glob_match("Makefile", "sub/Makefile"));
        assert!(glob_match("a?c", "abc"));
        let g = ["crates/**".to_string(), "!crates/**/tests/**".to_string()];
        assert!(inputs_match(&g, "crates/x/src/lib.rs"));
        assert!(!inputs_match(&g, "crates/x/tests/t.rs"));
        assert!(!inputs_match(&g, "crates/tests/t.rs"));
    }

    /// drgnx's pack globs (`drgnx/.drgnx/jobs.toml`'s image and build artifacts), copied here as a fixture.
    const IMAGE_GLOBS: &[&str] = &[
        "test/container/**",
        "rust-toolchain.toml",
        ".github/ci/mise.toml",
    ];
    const BUILD_GLOBS: &[&str] = &[
        "crates/**",
        "app/**",
        "Cargo.toml",
        "Cargo.lock",
        "!crates/**/tests/**",
    ];

    #[test]
    fn a_test_file_keeps_the_image_key_and_changes_only_matching_keys() {
        // [D] pure: a test file edit moves no image key; a source edit moves the build key and not the image key; an
        // edit under `tests/` is outside the build's globs
        let globs = |g: &[&str]| g.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let (image, build) = (globs(IMAGE_GLOBS), globs(BUILD_GLOBS));
        let tree = |lib: &str, test: &str, container: &str| {
            vec![
                ("crates/hub/x/src/lib.rs".to_string(), lib.to_string()),
                ("crates/hub/x/tests/t.rs".to_string(), test.to_string()),
                (
                    "test/container/Containerfile".to_string(),
                    container.to_string(),
                ),
                ("rust-toolchain.toml".to_string(), "t1".to_string()),
            ]
        };
        let key = |g: &[String], t: &[(String, String)]| {
            artifact_key(&KeyInputs {
                entry: pl(&[("inputs", Canon::List(g.iter().map(|x| s(x)).collect()))]),
                toolchain: "t".into(),
                blobs: t
                    .iter()
                    .filter(|(p, _)| inputs_match(g, p))
                    .cloned()
                    .collect(),
                overlay: vec![],
                used: vec![],
                inputs: vec![],
                recipe_files: vec![],
            })
        };
        let base = tree("l1", "t1", "c1");
        let test_edit = tree("l1", "t2", "c1");
        let src_edit = tree("l2", "t1", "c1");
        assert_eq!(key(&image, &base), key(&image, &test_edit));
        assert_eq!(key(&build, &base), key(&build, &test_edit));
        assert_eq!(key(&image, &base), key(&image, &src_edit));
        assert_ne!(key(&build, &base), key(&build, &src_edit));
        assert_ne!(key(&image, &base), key(&image, &tree("l1", "t1", "c2")));
    }

    #[test]
    fn a_toolchain_change_changes_every_key_that_names_it() {
        // [D] pure: the identity is in the key; an entry that names no toolchain keeps its key
        let d1 = format!("sha256:{}", "a".repeat(64));
        let d2 = format!("sha256:{}", "b".repeat(64));
        let key = |entry: &Canon, id: &str| {
            artifact_key(&KeyInputs {
                entry: entry.clone(),
                toolchain: id.into(),
                blobs: vec![],
                overlay: vec![],
                used: vec![],
                inputs: vec![],
                recipe_files: vec![],
            })
        };
        let (id1, id2) = (
            toolchain_identity(&d1).unwrap(),
            toolchain_identity(&d2).unwrap(),
        );
        for entry in [
            pl(&[("toolchain", s("gcc")), ("run", s("make"))]),
            pl(&[("toolchain", s("gcc")), ("run", s("make test"))]),
        ] {
            assert_ne!(key(&entry, &id1), key(&entry, &id2));
        }
        // a bare 64-hex digest is the same identity as its prefixed form
        assert_eq!(toolchain_identity(&"a".repeat(64)).unwrap(), id1);
        // the identity is a platform digest: anything else is refused
        for bad in ["", "latest", "sha256:abc", "sha512:aaaa", &"g".repeat(64)] {
            assert!(toolchain_identity(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_needed_key_has_one_register_id_per_role() {
        // [D] pure: the guard and the hub's pins name an artifact by the same id
        let k = ArtifactKey("c".repeat(64));
        assert_eq!(
            item_id(crate::Role::Gate, "p1", &k),
            format!("artifact:gate:p1:{}", k.0)
        );
        assert_eq!(
            item_ids("p1", &k),
            [
                format!("artifact:author:p1:{}", k.0),
                format!("artifact:gate:p1:{}", k.0)
            ]
        );
        assert_ne!(item_ids("p1", &k), item_ids("p2", &k));
    }
}
