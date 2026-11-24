//! The `image` kind: an artifact that is a container image.
//!
//! - **The key.** [`image_tag`] is CI's image tag rule (`test/container/image-tag.sh`) over the frozen tree: the first 16
//!   hex digits of a sha256 over the Containerfile, every file its `COPY` and `ADD` lines take from the build context,
//!   and the base image's tag. [`image_key`] adds the files of the entry's `tag-inputs` (the mise pins among them), so
//!   an edit of anything the image is made from is a new key and an unchanged image keeps its key.
//! - **The plan.** The hub asks the registry for the digest of this tree's tag only ([`plan_image`]): a registry that
//!   has it is pulled from by digest, one that lacks it means the runner builds the image from the tree. The registry's
//!   older image under another tag is never used for this key.
//! - **Use.** A job runs the image by its ID, and only when the image's label names the key
//!   ([`crate::linux::podman::ImageRef`]).

use std::collections::BTreeMap;

use forseti::ArtifactKey;
use sha2::{Digest, Sha256};

/// An `image` entry of a pack, as the hub reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageEntry {
    pub name: String,
    /// The registry repository (`host/name`), checked against the project's allow-list.
    pub registry_repo: String,
    /// Globs of the tree's files whose content is in the key besides what the tag rule reads (`.github/ci/mise.toml`).
    pub tag_inputs: Vec<String>,
    /// The Containerfile's path in the tree.
    pub containerfile: String,
    /// The build context's folder in the tree.
    pub context: String,
}

/// What the hub decides at submit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImagePlan {
    /// The registry has this key's image: the runner pulls it by this platform digest.
    Pull { digest: String },
    /// It has not: the runner builds the image from the tree.
    Build,
}

/// Pull when REGISTRY_DIGEST (the registry's digest for this key's own tag) is a platform digest, else build.
pub fn plan_image(_key: &ArtifactKey, registry_digest: Option<String>) -> ImagePlan {
    match registry_digest.filter(|d| digest_ok(d)) {
        Some(digest) => ImagePlan::Pull { digest },
        None => ImagePlan::Build,
    }
}

/// `sha256:` and 64 hex digits.
pub fn digest_ok(d: &str) -> bool {
    d.strip_prefix("sha256:").is_some_and(|h| {
        h.len() == 64
            && h.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// The files of a tree, as the tag rule reads them: by path, from the tree's root.
pub trait TreeFiles {
    /// The sha256 (hex) of the file at PATH; none when there is no such file.
    fn sha256(&self, path: &str) -> Option<String>;
    /// The text of the file at PATH.
    fn text(&self, path: &str) -> Option<String>;
    /// Whether PATH is a folder.
    fn is_dir(&self, path: &str) -> bool;
    /// Every file under the folder DIR, as paths from DIR (`a/b.txt`), in byte order.
    fn files_under(&self, dir: &str) -> Vec<String>;
}

fn sha_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The context sources of each `COPY` and `ADD` of TEXT, in order: continued lines joined, options and the destination
/// left out; a `COPY --from=` takes from another stage and a URL from no file here.
fn sources(text: &str) -> Vec<String> {
    let mut out = vec![];
    let mut line = String::new();
    for l in text.lines() {
        line.push_str(l);
        if line.ends_with('\\') {
            line.pop();
            line.push(' ');
            continue;
        }
        let joined = std::mem::take(&mut line);
        let w: Vec<&str> = joined
            .split([' ', '\t'])
            .filter(|x| !x.is_empty())
            .collect();
        let Some(op) = w.first() else { continue };
        if !(op.eq_ignore_ascii_case("COPY") || op.eq_ignore_ascii_case("ADD")) {
            continue;
        }
        let mut from = false;
        let mut args: Vec<&str> = vec![];
        for x in &w[1..] {
            if x.starts_with("--from=") {
                from = true;
            } else if !x.starts_with("--") {
                args.push(x);
            }
        }
        if !from && args.len() > 1 {
            out.extend(
                args[..args.len() - 1]
                    .iter()
                    .filter(|a| !a.contains("://"))
                    .map(|a| a.to_string()),
            );
        }
    }
    out
}

/// The base file a Containerfile names in a line `# base: NAME FILE` (the first one).
fn base_file(text: &str) -> Option<String> {
    text.lines().find_map(|l| {
        let w: Vec<&str> = l.split_whitespace().collect();
        (w.first() == Some(&"#") && w.get(1) == Some(&"base:") && w.len() >= 4)
            .then(|| w[3].to_string())
    })
}

fn dirname(path: &str) -> &str {
    path.rsplit_once('/').map_or(".", |(d, _)| d)
}

fn join(dir: &str, rel: &str) -> String {
    if dir == "." {
        rel.to_string()
    } else {
        format!("{dir}/{rel}")
    }
}

/// CI's tag of the image built from CONTAINERFILE in TREE: `image-tag.sh`'s rule, byte for byte. Err names the source a
/// `COPY` takes that the tree lacks (never a tag of part of the inputs).
pub fn image_tag(tree: &dyn TreeFiles, containerfile: &str) -> villa::Result<String> {
    tag_at(tree, containerfile, 0).map_err(villa::Error::invalid)
}

fn tag_at(tree: &dyn TreeFiles, containerfile: &str, depth: u8) -> Result<String, String> {
    if depth > 8 {
        return Err(format!("{containerfile}: bases nest too deep"));
    }
    let text = tree
        .text(containerfile)
        .ok_or_else(|| format!("{containerfile} is not in the tree"))?;
    let ctx = dirname(containerfile);
    let mut manifest = String::new();
    manifest.push_str(&sha_hex(text.as_bytes()));
    manifest.push('\n');
    if let Some(base) = base_file(&text) {
        let path = join(ctx, &base);
        if tree.text(&path).is_none() {
            return Err(format!(
                "{containerfile} names the base {base}, which is not in {ctx}"
            ));
        }
        manifest.push_str(&format!("base {}\n", tag_at(tree, &path, depth + 1)?));
    }
    for src in sources(&text) {
        // `find base/` and `find base` print the same names
        let named = src.trim_end_matches('/');
        let path = join(ctx, named);
        if tree.is_dir(&path) {
            for f in tree.files_under(&path) {
                let full = join(&path, &f);
                let sha = tree
                    .sha256(&full)
                    .ok_or_else(|| format!("{full} is not in the tree"))?;
                manifest.push_str(&format!("{sha}  {}\n", join(named, &f)));
            }
        } else if let Some(sha) = tree.sha256(&path) {
            manifest.push_str(&format!("{sha}  {src}\n"));
        } else {
            return Err(format!(
                "{containerfile} copies {src}, which is not in {ctx}"
            ));
        }
    }
    Ok(sha_hex(manifest.as_bytes())[..16].to_string())
}

/// The key of the image E at TAG ([`image_tag`]) with INPUTS (`(path, sha256)` of the tree's files that match
/// `tag_inputs`): it changes when the tag does, when any of those files does, and with the repository.
pub fn image_key(e: &ImageEntry, tag: &str, inputs: &[(String, String)]) -> ArtifactKey {
    let mut h = Sha256::new();
    let mut word = |w: &str| {
        h.update((w.len() as u64).to_le_bytes());
        h.update(w.as_bytes());
    };
    word("image/1");
    word(&e.registry_repo);
    word(tag);
    let mut sorted: Vec<&(String, String)> = inputs.iter().collect();
    sorted.sort();
    for (p, s) in sorted {
        word(p);
        word(s);
    }
    ArtifactKey(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// A tree of fixed files, for tests and for a hub that has the files read already.
#[derive(Clone, Debug, Default)]
pub struct MapTree(pub BTreeMap<String, Vec<u8>>);

impl TreeFiles for MapTree {
    fn sha256(&self, path: &str) -> Option<String> {
        self.0.get(path).map(|b| sha_hex(b))
    }
    fn text(&self, path: &str) -> Option<String> {
        self.0
            .get(path)
            .map(|b| String::from_utf8_lossy(b).into_owned())
    }
    fn is_dir(&self, path: &str) -> bool {
        let p = format!("{path}/");
        self.0.keys().any(|k| k.starts_with(&p))
    }
    fn files_under(&self, dir: &str) -> Vec<String> {
        let p = format!("{dir}/");
        // byte order, as `LC_ALL=C sort` has it (a BTreeMap iterates in that order)
        self.0
            .keys()
            .filter_map(|k| k.strip_prefix(&p).map(String::from))
            .collect()
    }
}

/// How a committed `image` artifact is recorded: `image.json` in its folder of the store.
pub const RECORD: &str = "image.json";

/// What the store's folder of an `image` artifact says about its image.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Recorded {
    /// podman's image ID.
    pub id: String,
    /// `built` (here, from the tree: the image carries the key's label) or `pulled` (by digest from the allow-listed
    /// registry, which the runner checked and recorded: the pairing is the proof).
    pub source: String,
    /// The reference it was pulled by.
    #[serde(default)]
    pub reference: Option<String>,
}

/// The label of image ID (the artifact key it was built for), read from podman; none: it has none.
pub fn label_of(id: &str) -> villa::Result<Option<String>> {
    let format = format!("{{{{ index .Config.Labels \"{}\" }}}}", super::LABEL);
    let out = crate::tool::limited(
        std::path::Path::new("podman"),
        &["image", "inspect", "--format", &format, id],
        &[],
        std::time::Duration::from_secs(60),
    )?;
    if !out.status.success() {
        return Err(villa::Error::not_found(format!(
            "podman image inspect {id}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok((!s.is_empty() && s != "<no value>").then_some(s))
}

/// The ID podman gives image REFERENCE (`podman image inspect`).
pub fn id_of(reference: &str) -> villa::Result<String> {
    let out = crate::tool::limited(
        std::path::Path::new("podman"),
        &["image", "inspect", "--format", "{{.Id}}", reference],
        &[],
        std::time::Duration::from_secs(60),
    )?;
    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() && !id.is_empty() {
        Ok(id.strip_prefix("sha256:").unwrap_or(&id).to_string())
    } else {
        Err(villa::Error::not_found(format!(
            "podman image inspect {reference}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}

/// The ID podman wrote to IIDFILE (`podman build --iidfile`), without its `sha256:`.
pub fn built_id(iidfile: &std::path::Path) -> villa::Result<String> {
    let text = crate::fsio::read_to_string(iidfile)
        .map_err(|e| villa::Error::io(format!("{}: {e}", iidfile.display())))?;
    let id = text.trim();
    Ok(id.strip_prefix("sha256:").unwrap_or(id).to_string())
}

/// The platform digest of the image for OS and ARCH in INDEX (an OCI image index or a manifest list, as JSON): the
/// manifest's digest, never the index's own. None: no such platform, or the document is not an index.
pub fn platform_digest(index: &str, os: &str, arch: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(index).ok()?;
    v.get("manifests")?
        .as_array()?
        .iter()
        .find(|m| {
            m["platform"]["os"].as_str() == Some(os)
                && m["platform"]["architecture"].as_str() == Some(arch)
        })
        .and_then(|m| m["digest"].as_str())
        .filter(|d| digest_ok(d))
        .map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::time::Duration;

    fn fixture() -> Vec<(&'static str, &'static str)> {
        vec![
            (
                "test/container/Containerfile.rust",
                "# base: dev base/dev.txt\nFROM base\nCOPY --chmod=0755 rust-packages.sh \\\n  nidhogg.sh /usr/local/bin/\nCOPY --from=builder /x /y\nADD https://example.org/a.tgz /opt/\nCOPY base/ /etc/base/\nRUN true\n",
            ),
            ("test/container/base/dev.txt", "base image one\n"),
            ("test/container/rust-packages.sh", "echo packages\n"),
            ("test/container/nidhogg.sh", "echo nidhogg\n"),
            ("test/container/base/a.cfg", "a\n"),
            ("test/container/base/z/b.cfg", "b\n"),
        ]
    }

    fn tree(files: &[(&str, &str)]) -> MapTree {
        MapTree(
            files
                .iter()
                .map(|(p, c)| (p.to_string(), c.as_bytes().to_vec()))
                .collect(),
        )
    }

    /// `image-tag.sh`'s output for FILES written under a temporary folder (the script is the repository's own).
    fn script_tag(files: &[(&str, &str)]) -> String {
        let t = tempfile::tempdir().unwrap();
        for (p, c) in files {
            let f = t.path().join(p);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            crate::fsio::write(&f, c).unwrap();
        }
        let script =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test/container/image-tag.sh");
        let file = t.path().join("test/container/Containerfile.rust");
        let out = crate::tool::limited(
            Path::new("/bin/bash"),
            &[script.as_os_str(), file.as_os_str()],
            &[],
            Duration::from_secs(60),
        )
        .unwrap();
        assert!(
            out.status.success(),
            "image-tag.sh: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().to_string()
    }

    #[test]
    fn the_hubs_tag_equals_image_tag_sh() {
        let files = fixture();
        let hub = image_tag(&tree(&files), "test/container/Containerfile.rust").unwrap();
        assert_eq!(hub.len(), 16);
        assert_eq!(hub, script_tag(&files));
        // and after edits to each kind of input: a copied file, a file in a copied folder, the base
        for (path, to) in [
            ("test/container/nidhogg.sh", "echo changed\n"),
            ("test/container/base/z/b.cfg", "B\n"),
            ("test/container/base/dev.txt", "base image two\n"),
        ] {
            let edited: Vec<(&str, &str)> = files
                .iter()
                .map(|(p, c)| (*p, if *p == path { to } else { *c }))
                .collect();
            let hub2 = image_tag(&tree(&edited), "test/container/Containerfile.rust").unwrap();
            assert_ne!(hub2, hub, "{path}");
            assert_eq!(hub2, script_tag(&edited), "{path}");
        }
    }

    #[test]
    fn a_source_the_tree_lacks_is_an_error_never_a_partial_tag() {
        let mut files = fixture();
        files.retain(|(p, _)| *p != "test/container/nidhogg.sh");
        let e = image_tag(&tree(&files), "test/container/Containerfile.rust")
            .unwrap_err()
            .message()
            .to_string();
        assert!(e.contains("nidhogg.sh"), "{e}");
    }

    #[test]
    fn a_mise_toml_change_changes_the_image_key() {
        let e = ImageEntry {
            name: "dev".into(),
            registry_repo: "registry.example/drgnx-ci".into(),
            tag_inputs: vec![".github/ci/mise.toml".into()],
            containerfile: "test/container/Containerfile.rust".into(),
            context: "test/container".into(),
        };
        let tag = image_tag(&tree(&fixture()), &e.containerfile).unwrap();
        let sha = |c: &str| sha_hex(c.as_bytes());
        let inputs = |c: &str| vec![(".github/ci/mise.toml".to_string(), sha(c))];
        let a = image_key(&e, &tag, &inputs("[tools]\nzig = \"0.15\"\n"));
        let b = image_key(&e, &tag, &inputs("[tools]\nzig = \"0.16\"\n"));
        assert_ne!(a, b);
        assert_eq!(a, image_key(&e, &tag, &inputs("[tools]\nzig = \"0.15\"\n")));
        assert_eq!(a.0.len(), 64);
        // the tag and the repository are in it too
        assert_ne!(
            a,
            image_key(&e, "0123456789abcdef", &inputs("[tools]\nzig = \"0.15\"\n"))
        );
        let other = ImageEntry {
            registry_repo: "registry.example/other".into(),
            ..e
        };
        assert_ne!(
            a,
            image_key(&other, &tag, &inputs("[tools]\nzig = \"0.15\"\n"))
        );
    }

    #[test]
    fn the_registry_is_asked_for_this_trees_tag_only() {
        // [D] pure: the plan is a pull only for a platform digest the registry gave for this key's own tag
        let key = ArtifactKey("1".repeat(64));
        let d = format!("sha256:{}", "a".repeat(64));
        assert_eq!(
            plan_image(&key, Some(d.clone())),
            ImagePlan::Pull { digest: d }
        );
        assert_eq!(plan_image(&key, None), ImagePlan::Build);
        // a reference that is not a platform digest is no pull
        assert_eq!(plan_image(&key, Some("latest".into())), ImagePlan::Build);
        assert_eq!(
            plan_image(&key, Some("sha256:abc".into())),
            ImagePlan::Build
        );
    }

    #[test]
    fn the_identity_is_the_platform_digest_not_the_index() {
        let amd = format!("sha256:{}", "1".repeat(64));
        let arm = format!("sha256:{}", "2".repeat(64));
        let index = format!(
            r#"{{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
              {{"digest":"{arm}","platform":{{"architecture":"arm64","os":"linux"}}}},
              {{"digest":"{amd}","platform":{{"architecture":"amd64","os":"linux"}}}}]}}"#
        );
        assert_eq!(platform_digest(&index, "linux", "amd64"), Some(amd));
        assert_eq!(platform_digest(&index, "linux", "arm64"), Some(arm));
        assert_eq!(platform_digest(&index, "linux", "riscv64"), None);
        // a single manifest has no `manifests`: its digest is what the registry gave, not read here
        assert_eq!(platform_digest(r#"{"layers":[]}"#, "linux", "amd64"), None);
        assert_eq!(platform_digest("not json", "linux", "amd64"), None);
    }
}
