//! Caches on a runner, partitioned by trust (docs/develop/sleipnir.md, "Disk and caches"; design 6.3).
//!
//! Every writable cache a job's suite declares is a folder `<root>/cache/<project>/<trust>/<name>/`, so a job of one
//! job trust never reads what a job of another wrote. `private+keys` jobs also get a fresh target dir of their own,
//! never the slot's, so a keyed release job never runs what an unkeyed job's `build.rs` left. Package caches (dnf and
//! the like) get one folder per running job: two runs on one dnf cache fail.

use std::path::{Path, PathBuf};

use forseti::JobTrust;

use super::slot::trust_word;

/// Each writable cache's budget (design 6.3; a setting): above it the guard prunes the cache between jobs.
pub const BUDGET: u64 = 10 << 30;

/// Where a job's target dir is inside its container.
pub const TARGET_INSIDE: &str = "/target";

/// One word of a cache's path as one path component: letters, digits, `_`, `-` and `.` (not first) stay, every other
/// byte is `%XX`, so no two words share a folder and none leaves its parent.
fn component(word: &str) -> String {
    if word.is_empty() {
        return "%".into();
    }
    let mut s = String::with_capacity(word.len());
    for (i, b) in word.bytes().enumerate() {
        if b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || (b == b'.' && i > 0) {
            s.push(b as char);
        } else {
            s.push_str(&format!("%{b:02X}"));
        }
    }
    s
}

/// The folder of cache `name` for `project`'s jobs of trust `trust`.
pub fn dir(root: &Path, project: &str, trust: JobTrust, name: &str) -> PathBuf {
    trust_dir(root, project, trust).join(component(name))
}

/// `<root>/cache/<project>/<trust>`.
fn trust_dir(root: &Path, project: &str, trust: JobTrust) -> PathBuf {
    root.join("cache")
        .join(component(project))
        .join(trust_word(trust))
}

/// The job trust a cache folder's `<trust>` word names.
pub(crate) fn trust_of(word: &str) -> Option<JobTrust> {
    [JobTrust::Public, JobTrust::Private, JobTrust::PrivateKeys]
        .into_iter()
        .find(|&t| trust_word(t) == word)
}

/// How a declared cache is shared.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CacheKind {
    /// By every job of the project at that trust (cargo home, ccache, the Lisp cache).
    Shared,
    /// One per running job (dnf and other package caches).
    PerJob,
}

/// A cache a job's suite declares, and where it goes inside the container.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SuiteCache {
    pub name: String,
    pub inside: String,
    pub kind: CacheKind,
}

/// What `mounts_for` needs to know of a job.
#[derive(Clone, Debug)]
pub struct CacheJob<'a> {
    pub root: &'a Path,
    pub project: &'a str,
    pub trust: JobTrust,
    /// The attempt's id, `<job>.<attempt>`: its folder is `<root>/jobs/<id>/`.
    pub id: &'a str,
    /// The slot's target dir.
    pub slot_target: &'a Path,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountKind {
    Target,
    Cache,
}

/// A host folder mounted read-write into the job's container.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mount {
    pub host: PathBuf,
    pub inside: String,
    pub kind: MountKind,
}

/// The job's target dir (first) and one mount per declared cache.
pub fn mounts_for(job: &CacheJob, suite_caches: &[SuiteCache]) -> Vec<Mount> {
    let target = match job.trust {
        JobTrust::PrivateKeys => job.root.join("jobs").join(component(job.id)).join("target"),
        JobTrust::Public | JobTrust::Private => job.slot_target.to_path_buf(),
    };
    let mut out = vec![Mount {
        host: target,
        inside: TARGET_INSIDE.into(),
        kind: MountKind::Target,
    }];
    for c in suite_caches {
        let host = match c.kind {
            CacheKind::Shared => dir(job.root, job.project, job.trust, &c.name),
            // `@` is never left as it is in a word, so `<name>@<id>` is no other cache's folder
            CacheKind::PerJob => trust_dir(job.root, job.project, job.trust).join(format!(
                "{}@{}",
                component(&c.name),
                component(job.id)
            )),
        };
        out.push(Mount {
            host,
            inside: c.inside.clone(),
            kind: MountKind::Cache,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const TRUSTS: [JobTrust; 3] = [JobTrust::Public, JobTrust::Private, JobTrust::PrivateKeys];

    fn job<'a>(root: &'a Path, trust: JobTrust, id: &'a str, target: &'a Path) -> CacheJob<'a> {
        CacheJob {
            root,
            project: "drgnx",
            trust,
            id,
            slot_target: target,
        }
    }

    fn caches() -> Vec<SuiteCache> {
        vec![
            SuiteCache {
                name: "cargo-home".into(),
                inside: "/cargo".into(),
                kind: CacheKind::Shared,
            },
            SuiteCache {
                name: "dnf".into(),
                inside: "/var/cache/dnf".into(),
                kind: CacheKind::PerJob,
            },
        ]
    }

    // [D] pure
    #[test]
    fn trust_levels_never_share_a_dir() {
        let root = Path::new("/r");
        let dirs: Vec<PathBuf> = TRUSTS
            .iter()
            .map(|&t| dir(root, "p", t, "ccache"))
            .collect();
        assert_eq!(dirs[0], root.join("cache/p/public/ccache"));
        assert_eq!(dirs[2], root.join("cache/p/private+keys/ccache"));
        for (i, a) in dirs.iter().enumerate() {
            for b in &dirs[i + 1..] {
                assert!(!a.starts_with(b) && !b.starts_with(a), "{a:?} and {b:?}");
            }
        }
        // odd words stay one component each, inside their parent, and never collide
        let words = ["a/b", "a_b", "a%2Fb", "..", ".", "", ".x", "-x"];
        let mut seen = Vec::new();
        for w in words {
            let d = dir(root, w, JobTrust::Public, w);
            assert_eq!(
                d.components().count(),
                root.components().count() + 4,
                "{w:?}: {d:?}"
            );
            assert!(d.starts_with(root.join("cache")));
            for c in d.strip_prefix(root).unwrap().components() {
                assert!(matches!(c, std::path::Component::Normal(_)), "{w:?}: {d:?}");
            }
            assert!(!seen.contains(&d), "{w:?} shares {d:?}");
            seen.push(d);
        }
    }

    // [D] pure
    #[test]
    fn a_keyed_job_never_mounts_an_unkeyed_cache_or_target() {
        let root = Path::new("/r");
        let target = root.join("slots-target/abc");
        let keyed = mounts_for(&job(root, JobTrust::PrivateKeys, "k.1", &target), &caches());
        assert_eq!(keyed[0].kind, MountKind::Target);
        assert_eq!(keyed[0].inside, TARGET_INSIDE);
        assert_ne!(keyed[0].host, target, "a keyed job gets a fresh target dir");
        assert!(keyed[0].host.starts_with(root.join("jobs/k.1")));
        for m in &keyed[1..] {
            assert_eq!(m.kind, MountKind::Cache);
            assert!(
                m.host.starts_with(root.join("cache/drgnx/private+keys")),
                "{m:?}"
            );
        }
        for t in [JobTrust::Public, JobTrust::Private] {
            let other = mounts_for(&job(root, t, "u.1", &target), &caches());
            assert_eq!(
                other[0].host, target,
                "unkeyed jobs build into the slot's target"
            );
            for m in &other {
                assert!(
                    keyed
                        .iter()
                        .all(|k| !k.host.starts_with(&m.host) && !m.host.starts_with(&k.host)),
                    "{m:?} is shared with the keyed job"
                );
            }
        }
    }

    // [D] pure
    #[test]
    fn two_running_jobs_never_share_a_dnf_cache() {
        let root = Path::new("/r");
        let target = root.join("slots-target/abc");
        let a = mounts_for(&job(root, JobTrust::Private, "a.1", &target), &caches());
        let b = mounts_for(&job(root, JobTrust::Private, "b.1", &target), &caches());
        let at = |ms: &[Mount], inside: &str| {
            ms.iter().find(|m| m.inside == inside).unwrap().host.clone()
        };
        assert_eq!(
            at(&a, "/cargo"),
            at(&b, "/cargo"),
            "a shared cache is shared"
        );
        assert_ne!(at(&a, "/var/cache/dnf"), at(&b, "/var/cache/dnf"));
        assert!(!at(&a, "/var/cache/dnf").starts_with(at(&b, "/var/cache/dnf")));
        assert!(at(&a, "/var/cache/dnf").starts_with(root.join("cache/drgnx/private")));
        assert_eq!(a.len(), 3);
    }
}
