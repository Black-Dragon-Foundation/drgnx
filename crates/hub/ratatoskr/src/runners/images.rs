//! The hub's decision for an `image` artifact (docs/develop/hub.md, "Runners: artifacts"): pull the registry's image
//! by digest, or have the runner build it from the tree.
//!
//! The registry is asked for the digest of this tree's own tag only (`sleipnir::artifact::image::image_tag`), once per
//! tag ([`TagDigests`]). A registry that has the tag gives a platform digest the runner pulls; one that lacks it means
//! the runner builds, and an older image under another tag is never offered for this key.

use std::collections::BTreeMap;

use forseti::{ArtifactKey, ImageBuild};
use sleipnir::artifact::image::{self, ImageEntry, ImagePlan, TreeFiles};

/// The registry's side: the platform digest of `repo:tag` for this machine's platforms, or none when it has no such tag.
pub trait Registry {
    fn digest(&self, repo: &str, tag: &str) -> Option<String>;
}

/// The answers so far, per `(repo, tag)`: a tag is asked of the registry once.
#[derive(Default)]
pub struct TagDigests {
    seen: BTreeMap<(String, String), Option<String>>,
    asked: u32,
}

impl TagDigests {
    /// The registry's digest for `repo:tag`, asked once.
    pub fn digest(&mut self, reg: &dyn Registry, repo: &str, tag: &str) -> Option<String> {
        let key = (repo.to_string(), tag.to_string());
        if let Some(d) = self.seen.get(&key) {
            return d.clone();
        }
        self.asked += 1;
        let d = reg.digest(repo, tag);
        self.seen.insert(key, d.clone());
        d
    }

    /// How many times the registry was asked.
    pub fn asked(&self) -> u32 {
        self.asked
    }
}

/// The `image` artifact's key and recipe for ENTRY over TREE: the tag rule over the tree, the registry asked for that tag
/// only, and the plan. `inputs` are the tag-input files' `(path, content hash)`.
pub fn plan(
    entry: &ImageEntry,
    tree: &dyn TreeFiles,
    inputs: &[(String, String)],
    reg: &dyn Registry,
    cache: &mut TagDigests,
    allow: Vec<String>,
) -> villa::Result<(ArtifactKey, ImageBuild)> {
    let tag = image::image_tag(tree, &entry.containerfile)?;
    let key = image::image_key(entry, &tag, inputs);
    let digest = match image::plan_image(&key, cache.digest(reg, &entry.registry_repo, &tag)) {
        ImagePlan::Pull { digest } => Some(digest),
        ImagePlan::Build => None,
    };
    Ok((
        key,
        ImageBuild {
            containerfile: entry.containerfile.clone(),
            context: entry.context.clone(),
            repo: entry.registry_repo.clone(),
            digest,
            index: None,
            allow,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sleipnir::artifact::image::MapTree;
    use std::cell::RefCell;

    /// A registry holding images by tag, counting its questions.
    struct Fake {
        has: BTreeMap<String, String>,
        asked: RefCell<Vec<String>>,
    }

    impl Registry for Fake {
        fn digest(&self, _repo: &str, tag: &str) -> Option<String> {
            self.asked.borrow_mut().push(tag.to_string());
            self.has.get(tag).cloned()
        }
    }

    fn entry() -> ImageEntry {
        ImageEntry {
            name: "ci".into(),
            registry_repo: "registry.example/ci".into(),
            tag_inputs: vec![],
            containerfile: "Containerfile".into(),
            context: ".".into(),
        }
    }

    fn tree(base: &str) -> MapTree {
        MapTree(
            [(
                "Containerfile".to_string(),
                format!("FROM {base}\n").into_bytes(),
            )]
            .into(),
        )
    }

    fn digest(c: char) -> String {
        format!("sha256:{}", c.to_string().repeat(64))
    }

    // [D] pure
    #[test]
    fn the_image_is_pulled_by_digest_when_the_registry_has_its_tag() {
        let t = tree("fedora:45");
        let tag = image::image_tag(&t, "Containerfile").unwrap();
        let reg = Fake {
            has: [(tag, digest('a'))].into(),
            asked: RefCell::default(),
        };
        let (_, b) = plan(&entry(), &t, &[], &reg, &mut TagDigests::default(), vec![]).unwrap();
        assert_eq!(b.digest, Some(digest('a')));
    }

    // [D] pure: the tree's inputs changed, so its tag is new: the registry has none, the runner builds, and the question
    // is asked once however many jobs name the image
    #[test]
    fn a_tree_whose_image_inputs_changed_builds_locally_once() {
        let old = tree("fedora:44");
        let old_tag = image::image_tag(&old, "Containerfile").unwrap();
        let reg = Fake {
            has: [(old_tag, digest('b'))].into(),
            asked: RefCell::default(),
        };
        let new = tree("fedora:45");
        let mut cache = TagDigests::default();
        let (k1, b1) = plan(&entry(), &new, &[], &reg, &mut cache, vec![]).unwrap();
        let (k2, b2) = plan(&entry(), &new, &[], &reg, &mut cache, vec![]).unwrap();
        assert_eq!((b1.digest, b2.digest), (None, None));
        assert_eq!(k1, k2);
        assert_eq!(cache.asked(), 1, "{:?}", reg.asked);
    }

    // [D] pure: the registry's older image is under an older tag: it is never the answer for the new tree
    #[test]
    fn a_tree_whose_image_inputs_changed_never_runs_on_the_registrys_older_image() {
        let old = tree("fedora:44");
        let old_tag = image::image_tag(&old, "Containerfile").unwrap();
        let reg = Fake {
            has: [(old_tag.clone(), digest('b'))].into(),
            asked: RefCell::default(),
        };
        let (_, b) = plan(
            &entry(),
            &tree("fedora:45"),
            &[],
            &reg,
            &mut TagDigests::default(),
            vec![],
        )
        .unwrap();
        assert_ne!(b.digest, Some(digest('b')));
        assert!(!reg.asked.borrow().contains(&"latest".to_string()));
        assert!(!reg.asked.borrow().contains(&old_tag), "{:?}", reg.asked);
    }
}
