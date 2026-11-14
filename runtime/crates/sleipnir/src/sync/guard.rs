//! The runner's disk guard (docs/develop/sleipnir.md, "Disk and caches"; design 6.3).
//!
//! Before every admission it keeps at least 20 GB and 10 % of the runner folder's filesystem free. Below that it
//! prunes, in the design's order:
//!
//! 1. collected job folders (or older than 24 h);
//! 2. artifacts no queued job needs;
//! 3. slots unused for 7 days, target dir first;
//! 4. caches over their budget, then the others, lowest trust first and least recently used first;
//! 5. images we pulled that no queued job names.
//!
//! Caches over their budget are pruned between jobs even above the floor. `plan` is pure; free space comes from
//! `statvfs` (`df`), never from adding up sizes, and `apply` re-reads it before every prune it does for the floor.
//! `apply` never leaves the runner folder and never follows a link: every path is opened component by component with
//! `O_NOFOLLOW`, and a link is removed as a link. It never removes an image we didn't pull.

use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Write};
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

use forseti::JobTrust;
use rustix::fs::{AtFlags, Dir, FileType, Mode, OFlags, open, openat, statat, unlinkat};

use super::cache::trust_of;
use super::slot::{Locks, SlotPaths, UNUSED_FOR};
use super::{Result, refused};

/// The floor's fixed part: 20 GB.
pub const FLOOR_BYTES: u64 = 20_000_000_000;
/// A job folder this old is pruned like a collected one.
pub const JOB_FOLDER_AGE: Duration = Duration::from_secs(24 * 3600);
/// The marker `serve` writes into a job folder once the hub has its results.
pub const COLLECTED: &str = "collected";

/// What `statvfs` says of the runner folder's filesystem, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Df {
    pub total: u64,
    pub avail: u64,
}

impl Df {
    /// The floor: 20 GB and 10 % of the filesystem, whichever is more.
    pub fn floor(&self) -> u64 {
        FLOOR_BYTES.max(self.total / 10)
    }

    pub fn below_floor(&self) -> bool {
        self.avail < self.floor()
    }
}

/// `statvfs` of `path`.
pub fn df(path: &Path) -> io::Result<Df> {
    let s = rustix::fs::statvfs(path)?;
    Ok(Df {
        total: s.f_blocks * s.f_frsize,
        avail: s.f_bavail * s.f_frsize,
    })
}

/// Something under the runner folder the guard may prune. Paths are relative to the folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    JobFolder {
        rel: PathBuf,
        collected: bool,
    },
    Artifact {
        rel: PathBuf,
        job: String,
    },
    /// A slot (`slots/<id>`, `slots-git/<id>`, `slots-target/<id>`).
    Slot {
        id: String,
        unused_for: Duration,
    },
    Cache {
        rel: PathBuf,
        trust: JobTrust,
        bytes: u64,
        budget: u64,
        last_used: SystemTime,
    },
    /// An image in the runner's podman store: its id, and the references we pulled it by (none: not ours).
    Image {
        id: String,
        pulled_as: Vec<String>,
    },
}

/// What queued jobs need: artifacts by job id, images by reference.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Needs {
    pub artifacts: BTreeSet<String>,
    pub images: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum What {
    /// A file or folder under the runner folder, removed whole.
    Path(PathBuf),
    /// A slot's checkout and git dir, under its update lock (its target dir is a `Path` before it).
    Slot(String),
    /// An image, by id.
    Image(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prune {
    pub what: What,
    /// Done only while the filesystem is below the floor (otherwise: a cache over its budget).
    pub for_floor: bool,
}

/// The prunes for `items`, in the design's order. Above the floor, only caches over their budget.
pub fn plan(df: Df, items: &[Item], queued_needs: &Needs) -> Vec<Prune> {
    let floor = df.below_floor();
    let mut out = Vec::new();
    let mut push = |what, for_floor| out.push(Prune { what, for_floor });
    if floor {
        for i in items {
            if let Item::JobFolder {
                rel,
                collected: true,
            } = i
            {
                push(What::Path(rel.clone()), true);
            }
        }
        for i in items {
            if let Item::Artifact { rel, job } = i
                && !queued_needs.artifacts.contains(job)
            {
                push(What::Path(rel.clone()), true);
            }
        }
        for i in items {
            if let Item::Slot { id, unused_for } = i
                && *unused_for >= UNUSED_FOR
            {
                push(What::Path(Path::new("slots-target").join(id)), true);
                push(What::Slot(id.clone()), true);
            }
        }
    }
    let mut caches: Vec<(u8, SystemTime, &PathBuf, bool)> = items
        .iter()
        .filter_map(|i| match i {
            Item::Cache {
                rel,
                trust,
                bytes,
                budget,
                last_used,
            } => Some((rank(*trust), *last_used, rel, bytes > budget)),
            _ => None,
        })
        .collect();
    caches.sort();
    for (_, _, rel, over) in &caches {
        if *over {
            push(What::Path((*rel).clone()), false);
        }
    }
    if floor {
        for (_, _, rel, over) in &caches {
            if !over {
                push(What::Path((*rel).clone()), true);
            }
        }
        for i in items {
            if let Item::Image { id, pulled_as } = i
                && !pulled_as.is_empty()
                && !pulled_as.iter().any(|r| queued_needs.images.contains(r))
            {
                push(What::Image(id.clone()), true);
            }
        }
    }
    out
}

/// Lowest trust first: what a public job wrote is the cheapest to lose.
fn rank(t: JobTrust) -> u8 {
    match t {
        JobTrust::Public => 0,
        JobTrust::Private => 1,
        JobTrust::PrivateKeys => 2,
    }
}

/// Does `plan` under the runner folder `root`, re-reading `df` before every prune for the floor and skipping those
/// once the floor is reached (or `df` fails). Returns each prune tried with its outcome; a failed one (a link in the
/// way, a slot in use) is skipped.
pub fn apply(
    root: &Path,
    plan: &[Prune],
    df: &mut dyn FnMut() -> io::Result<Df>,
) -> Vec<(Prune, io::Result<()>)> {
    let mut out = Vec::new();
    for p in plan {
        if p.for_floor && !df().is_ok_and(|d| d.below_floor()) {
            continue;
        }
        let r = match &p.what {
            What::Path(rel) => remove_beneath(root, rel),
            What::Slot(id) => remove_slot(root, id),
            What::Image(id) => remove_image(id),
        };
        out.push((p.clone(), r));
    }
    out
}

/// Removes `root/rel` whole. Each folder on the way is opened with `O_NOFOLLOW` (a link there fails the prune), and
/// below it nothing is followed: a link is removed as a link.
fn remove_beneath(root: &Path, rel: &Path) -> io::Result<()> {
    let names = rel
        .components()
        .map(|c| match c {
            Component::Normal(n) => Ok(n),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{}: not a plain relative path", rel.display()),
            )),
        })
        .collect::<io::Result<Vec<&OsStr>>>()?;
    let Some((last, parents)) = names.split_last() else {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "an empty path"));
    };
    let mut dir = open(
        root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    for n in parents {
        dir = openat(&dir, *n, DIR_NOFOLLOW, Mode::empty())?;
    }
    remove_at(&dir, last)
}

const DIR_NOFOLLOW: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);

fn remove_at(dir: &OwnedFd, name: &OsStr) -> io::Result<()> {
    let st = statat(dir, name, AtFlags::SYMLINK_NOFOLLOW)?;
    if FileType::from_raw_mode(st.st_mode as _) == FileType::Directory {
        let sub = openat(dir, name, DIR_NOFOLLOW, Mode::empty())?;
        let mut names = Vec::new();
        for e in Dir::read_from(&sub)? {
            let e = e?;
            let n = e.file_name().to_bytes();
            if n != b"." && n != b".." {
                names.push(OsStr::from_bytes(n).to_os_string());
            }
        }
        for n in &names {
            remove_at(&sub, n)?;
        }
        unlinkat(dir, name, AtFlags::REMOVEDIR)?;
    } else {
        unlinkat(dir, name, AtFlags::empty())?;
    }
    Ok(())
}

/// A slot's checkout and git dir, under its update lock: a slot in use is kept.
fn remove_slot(root: &Path, id: &str) -> io::Result<()> {
    if id.is_empty() || id.contains('/') || id == "." || id == ".." {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a slot id"));
    }
    let p = SlotPaths {
        slot: root.join("slots").join(id),
        git_dir: root.join("slots-git").join(id),
        target: root.join("slots-target").join(id),
    };
    let held = Locks::of(&p)
        .try_update()
        .map_err(|e| io::Error::other(e.to_string()))?;
    let Some(_held) = held else {
        return Err(io::Error::other(format!("slot {id} is in use")));
    };
    for d in ["slots", "slots-git"] {
        match remove_beneath(root, &Path::new(d).join(id)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    Ok(())
}

fn remove_image(id: &str) -> io::Result<()> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not an image id",
        ));
    }
    let out = Command::new("podman")
        .args(["image", "rm", id])
        .stdin(Stdio::null())
        .output()?;
    if out.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "podman image rm {id}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}

/// The folder's prunable items besides images: job folders, artifacts, slots and caches (each cache's size by a walk
/// that never follows a link, for its budget only). A link where one of these folders belongs is never followed and
/// never listed.
pub fn scan(root: &Path, now: SystemTime, budget: u64) -> Result<Vec<Item>> {
    let age = |p: &Path| {
        fs::symlink_metadata(p)
            .and_then(|m| m.modified())
            .map(|t| now.duration_since(t).unwrap_or_default())
    };
    let mut out = Vec::new();
    for (name, path) in dirs(&root.join("jobs"))? {
        let collected =
            fs::symlink_metadata(path.join(COLLECTED)).is_ok() || age(&path)? >= JOB_FOLDER_AGE;
        out.push(Item::JobFolder {
            rel: Path::new("jobs").join(&name),
            collected,
        });
    }
    for (name, _) in dirs(&root.join("artifacts"))? {
        let n = name.to_string_lossy();
        let job = n.rsplit_once('.').map_or(&n[..], |(j, _)| j).to_string();
        out.push(Item::Artifact {
            rel: Path::new("artifacts").join(&name),
            job,
        });
    }
    for (name, path) in dirs(&root.join("slots-git"))? {
        let unused_for = age(&path.join("used")).or_else(|_| age(&path))?;
        out.push(Item::Slot {
            id: name.to_string_lossy().into_owned(),
            unused_for,
        });
    }
    for (project, pp) in dirs(&root.join("cache"))? {
        for (t, tp) in dirs(&pp)? {
            let Some(trust) = t.to_str().and_then(trust_of) else {
                continue;
            };
            for (name, np) in dirs(&tp)? {
                out.push(Item::Cache {
                    rel: Path::new("cache").join(&project).join(&t).join(&name),
                    trust,
                    bytes: size(&np),
                    budget,
                    last_used: fs::symlink_metadata(&np)?.modified()?,
                });
            }
        }
    }
    Ok(out)
}

/// The real folders (never links) in `d`, by name; none when `d` isn't there.
fn dirs(d: &Path) -> io::Result<Vec<(OsString, PathBuf)>> {
    let rd = match fs::read_dir(d) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
        r => r?,
    };
    let mut out = Vec::new();
    for e in rd {
        let e = e?;
        if e.file_type()?.is_dir() {
            out.push((e.file_name(), e.path()));
        }
    }
    out.sort();
    Ok(out)
}

/// The bytes of the files under `d`, never following a link.
fn size(d: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(d) else { return 0 };
    rd.flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => size(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map_or(0, |m| m.len()),
            _ => 0,
        })
        .sum()
}

/// The images in the runner's podman store, with the references we pulled each by (`<root>/images`).
pub fn images(root: &Path) -> Result<Vec<Item>> {
    let ours = pulled(root)?;
    let out = Command::new("podman")
        .args(["images", "--no-trunc", "--format", "{{.ID}}"])
        .stdin(Stdio::null())
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "podman images: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ))
        .into());
    }
    let mut ids: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| bare_id(l).to_string())
        .filter(|l| !l.is_empty())
        .collect();
    ids.sort();
    ids.dedup();
    Ok(ids
        .into_iter()
        .map(|id| Item::Image {
            pulled_as: ours
                .iter()
                .filter(|(i, _)| *i == id)
                .map(|(_, r)| r.clone())
                .collect(),
            id,
        })
        .collect())
}

fn bare_id(s: &str) -> &str {
    let s = s.trim();
    s.strip_prefix("sha256:").unwrap_or(s)
}

/// `<root>/images`: one line `<image id> <reference>` per image we pulled.
fn pulled(root: &Path) -> io::Result<Vec<(String, String)>> {
    let text = match fs::read_to_string(root.join(IMAGES)) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
        r => r?,
    };
    Ok(text
        .lines()
        .filter_map(|l| l.split_once(' '))
        .map(|(id, r)| (bare_id(id).to_string(), r.trim().to_string()))
        .collect())
}

const IMAGES: &str = "images";

/// An image reference we may pull: `<repository>@sha256:<64 hex>`, its repository on the project's allow-list.
pub fn check_pull(reference: &str, allow: &[String]) -> Result<()> {
    let bad = |why| Err(refused(reference.as_bytes(), why));
    let Some((repo, digest)) = reference.split_once("@sha256:") else {
        return bad("an image is pulled by digest only");
    };
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return bad("not a sha256 digest");
    }
    if repo.starts_with('-') || !allow.iter().any(|a| a == repo) {
        return bad("not on the project's image allow-list");
    }
    Ok(())
}

/// Pulls `reference` (checked by `check_pull`) and records it as ours. Jobs run `--pull=never`.
pub fn pull(root: &Path, reference: &str, allow: &[String]) -> Result<String> {
    check_pull(reference, allow)?;
    let out = Command::new("podman")
        .args(["pull", "-q", reference])
        .stdin(Stdio::null())
        .output()?;
    let id = bare_id(
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .last()
            .unwrap_or(""),
    )
    .to_string();
    if !out.status.success() || id.is_empty() {
        return Err(io::Error::other(format!(
            "podman pull {reference}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ))
        .into());
    }
    fs::create_dir_all(root)?;
    let mut f = fs::File::options()
        .append(true)
        .create(true)
        .open(root.join(IMAGES))?;
    writeln!(f, "{id} {reference}")?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1_000_000_000;

    fn low() -> Df {
        Df {
            total: 500 * GB,
            avail: 10 * GB,
        }
    }

    fn high() -> Df {
        Df {
            total: 500 * GB,
            avail: 200 * GB,
        }
    }

    fn cache(rel: &str, trust: JobTrust, bytes: u64, age_s: u64) -> Item {
        Item::Cache {
            rel: rel.into(),
            trust,
            bytes,
            budget: 10 << 30,
            last_used: SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000 - age_s),
        }
    }

    fn paths(p: &[Prune]) -> Vec<String> {
        p.iter()
            .map(|p| match &p.what {
                What::Path(r) => r.display().to_string(),
                What::Slot(id) => format!("slot {id}"),
                What::Image(id) => format!("image {id}"),
            })
            .collect()
    }

    fn mixed() -> Vec<Item> {
        let week = Duration::from_secs(7 * 24 * 3600);
        vec![
            Item::Image {
                id: "ours-needed".into(),
                pulled_as: vec!["q.io/a@sha256:1".into()],
            },
            cache("cache/p/private/old", JobTrust::Private, 1, 500),
            Item::Slot {
                id: "fresh".into(),
                unused_for: week - Duration::from_secs(1),
            },
            Item::Artifact {
                rel: "artifacts/j2.1".into(),
                job: "j2".into(),
            },
            Item::JobFolder {
                rel: "jobs/run.1".into(),
                collected: false,
            },
            cache("cache/p/public/new", JobTrust::Public, 1, 10),
            Item::Image {
                id: "not-ours".into(),
                pulled_as: vec![],
            },
            Item::Slot {
                id: "stale".into(),
                unused_for: week,
            },
            cache(
                "cache/p/private+keys/huge",
                JobTrust::PrivateKeys,
                11 << 30,
                1,
            ),
            Item::Artifact {
                rel: "artifacts/j1.1".into(),
                job: "j1".into(),
            },
            Item::JobFolder {
                rel: "jobs/done.1".into(),
                collected: true,
            },
            cache("cache/p/public/old", JobTrust::Public, 1, 900),
            Item::Image {
                id: "ours".into(),
                pulled_as: vec!["q.io/b@sha256:2".into()],
            },
        ]
    }

    fn needs() -> Needs {
        Needs {
            artifacts: ["j1".to_string()].into(),
            images: ["q.io/a@sha256:1".to_string()].into(),
        }
    }

    // [D] pure
    #[test]
    fn prunes_in_the_designs_order() {
        let p = plan(low(), &mixed(), &needs());
        assert_eq!(
            paths(&p),
            [
                "jobs/done.1",
                "artifacts/j2.1",
                "slots-target/stale",
                "slot stale",
                "cache/p/private+keys/huge",
                "cache/p/public/old",
                "cache/p/public/new",
                "cache/p/private/old",
                "image ours",
            ]
        );
        assert!(!p[4].for_floor, "a cache over its budget goes anyway");
        assert!(p.iter().enumerate().all(|(i, x)| x.for_floor == (i != 4)));
    }

    // [D] pure
    #[test]
    fn trusts_statvfs_not_du() {
        // the items' sizes add up to far more than the shortfall, or to far less: only df decides
        let mut items = mixed();
        items.push(cache("cache/p/public/tiny", JobTrust::Public, 0, 5));
        let above = plan(high(), &items, &needs());
        assert_eq!(
            paths(&above),
            ["cache/p/private+keys/huge"],
            "above the floor, budgets only"
        );
        let tiny: Vec<Item> = vec![
            Item::JobFolder {
                rel: "jobs/a.1".into(),
                collected: true,
            },
            Item::JobFolder {
                rel: "jobs/b.1".into(),
                collected: true,
            },
        ];
        assert_eq!(plan(low(), &tiny, &Needs::default()).len(), 2);
        assert!(high().floor() == 50 * GB && !high().below_floor());
        assert!(
            Df {
                total: 100 * GB,
                avail: 19 * GB
            }
            .below_floor(),
            "20 GB at least"
        );

        // apply re-reads df before each prune for the floor and stops once it is above
        let t = tempfile::tempdir().unwrap();
        for d in ["jobs/a.1/x", "jobs/b.1/x"] {
            std::fs::create_dir_all(t.path().join(d)).unwrap();
        }
        let mut reads = vec![high(), low()];
        let done = apply(
            t.path(),
            &plan(low(), &tiny, &Needs::default()),
            &mut || Ok(reads.pop().unwrap()),
        );
        assert_eq!(done.len(), 1, "the second prune found the floor reached");
        assert!(done[0].1.is_ok());
        assert!(!t.path().join("jobs/a.1").exists());
        assert!(t.path().join("jobs/b.1/x").exists());
    }

    // [D] pure
    #[test]
    fn pulls_take_digests_from_the_allow_list_only() {
        let allow = vec!["registry.fedoraproject.org/fedora".to_string()];
        let d = "a".repeat(64);
        check_pull(
            &format!("registry.fedoraproject.org/fedora@sha256:{d}"),
            &allow,
        )
        .unwrap();
        for bad in [
            "registry.fedoraproject.org/fedora:45".to_string(),
            "registry.fedoraproject.org/fedora".to_string(),
            format!(
                "registry.fedoraproject.org/fedora@sha256:{}",
                "a".repeat(63)
            ),
            format!("docker.io/library/fedora@sha256:{d}"),
            format!("registry.fedoraproject.org/fedora-evil@sha256:{d}"),
            format!("-registry.fedoraproject.org/fedora@sha256:{d}"),
        ] {
            assert!(check_pull(&bad, &allow).is_err(), "{bad}");
        }
    }
}
