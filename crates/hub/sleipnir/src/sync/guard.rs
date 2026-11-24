//! The runner's disk guard (docs/develop/sleipnir.md, "Disk and caches"; editing-model design §4.8).
//!
//! It removes only what the disk register ([`super::register`]) holds, never by path pattern. Below the evict floor
//! ([`DiskRules::evict_below_gb`] free), or while what drgnx keeps is over the owner's quota, it evicts in §4.8's
//! order:
//!
//! 1. job folders the hub has collected (and their outputs);
//! 2. artifacts no queued job needs;
//! 3. idle build dirs, least recently used first;
//! 4. idle slots;
//! 5. caches over their budget, then the rest, lowest trust first;
//! 6. unpinned images, keeping the newest two per name.
//!
//! Below the floor an item goes only once its kind's age has passed ([`forseti::disk::state_of`]); the quota takes
//! pinned and young items too, never an active one. The pass stops once the floor is met. Above it, only caches over
//! their budget are trimmed. `plan` is pure; free space comes from `statvfs` (`df`), never from adding up sizes, and
//! `apply` re-reads it before every eviction for the floor.
//!
//! `apply` re-checks each item before removing it (`live`: a running job, the hub's pins; a slot's and a build dir's
//! locks) and records every refusal. It waits while IO is under pressure, at most `pace_max_s` per removal. It never
//! leaves the runner folder and never follows a link: every path is opened component by component with `O_NOFOLLOW`,
//! and a link is removed as a link. An `unknown` folder is reported and kept. An image the register doesn't hold (one
//! we didn't pull) is never removed.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};
use std::time::Duration;

use forseti::disk::{DiskItem, DiskRules, ItemKind, ItemState, state_of};
use rustix::fs::{AtFlags, Dir, FileType, Mode, OFlags, open, openat, statat, unlinkat};

pub use forseti::disk::{Evict, Evicted, Pins, Why};

use super::register::{Register, epoch_s};
use super::slot::{Locks, SlotPaths};
use super::{Result, refused};

/// A gigabyte, as §4.8's floors and quotas count it.
pub const GB: u64 = 1_000_000_000;

/// What `statvfs` says of the runner folder's filesystem, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Df {
    pub total: u64,
    pub avail: u64,
}

impl Df {
    /// Whether the filesystem is below R's evict floor.
    pub fn below_evict(&self, r: &DiskRules) -> bool {
        self.avail < r.evict_below_gb.saturating_mul(GB)
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

/// The step of §4.8's order an item's kind is evicted in (the other lines' kinds, should a runner hold one, last).
fn step(k: ItemKind) -> u8 {
    match k {
        ItemKind::JobFolder | ItemKind::Output => 1,
        ItemKind::Artifact => 2,
        ItemKind::BuildDir => 3,
        ItemKind::Slot => 4,
        ItemKind::Cache => 5,
        ItemKind::Image => 6,
        ItemKind::StreamWorktree
        | ItemKind::StreamLog
        | ItemKind::RecordsBackup
        | ItemKind::StoreBackup
        | ItemKind::Recording
        | ItemKind::Unknown => 7,
    }
}

/// Lowest trust first: what a public job wrote is the cheapest to lose.
fn rank(t: forseti::JobTrust) -> u8 {
    match t {
        forseti::JobTrust::Public => 0,
        forseti::JobTrust::Private => 1,
        forseti::JobTrust::PrivateKeys => 2,
    }
}

fn over_budget(i: &DiskItem) -> bool {
    i.kind == ItemKind::Cache && i.budget_bytes.is_some_and(|b| i.bytes > b)
}

/// The images that are among the newest `keep` of their name (an image with no name is its own name: kept).
fn newest_images(items: &[DiskItem], keep: u32) -> BTreeSet<&str> {
    let mut by_name: BTreeMap<&str, Vec<&DiskItem>> = BTreeMap::new();
    for i in items.iter().filter(|i| i.kind == ItemKind::Image) {
        by_name
            .entry(i.name.as_deref().unwrap_or(&i.id))
            .or_default()
            .push(i);
    }
    let mut out = BTreeSet::new();
    for (_, mut v) in by_name {
        v.sort_by(|a, b| b.created.cmp(&a.created).then_with(|| a.id.cmp(&b.id)));
        out.extend(v.iter().take(keep as usize).map(|i| i.id.as_str()));
    }
    out
}

/// The evictions for ITEMS at NOW, in §4.8's order: first what the owner's quota needs (OURS, the bytes drgnx keeps,
/// down to `quota_gb`), then, below the evict floor, every item past its age (`apply` stops these once the floor is
/// met), then caches over their budget. An active or `unknown` item is never planned.
pub fn plan(
    df: Df,
    ours: u64,
    items: &[DiskItem],
    pins: &Pins,
    r: &DiskRules,
    now: u64,
) -> Vec<Evict> {
    let state = |i: &DiskItem| state_of(i, now, &pins.active, &pins.pinned, r);
    let newest = newest_images(items, r.keep_images_per_name);
    let mut order: Vec<&DiskItem> = items
        .iter()
        .filter(|i| i.kind != ItemKind::Unknown && state(i) != ItemState::Active)
        .collect();
    order.sort_by_key(|i| {
        let trust = if i.kind == ItemKind::Cache {
            rank(i.trust)
        } else {
            0
        };
        let age_key = if i.kind == ItemKind::Image {
            i.created
        } else {
            i.last_used
        };
        (step(i.kind), !over_budget(i), trust, age_key, i.id.clone())
    });
    let mut out: Vec<Evict> = Vec::new();
    let mut taken: BTreeSet<&str> = BTreeSet::new();
    if let Some(q) = r.quota_gb {
        let cap = q.saturating_mul(GB);
        let mut kept = ours;
        for i in &order {
            if kept <= cap {
                break;
            }
            kept = kept.saturating_sub(i.bytes);
            taken.insert(&i.id);
            out.push(Evict {
                id: i.id.clone(),
                why: Why::Quota,
            });
        }
    }
    if df.below_evict(r) {
        for i in &order {
            let s = state(i);
            let may = match i.kind {
                ItemKind::Image => s != ItemState::Pinned && !newest.contains(i.id.as_str()),
                ItemKind::Cache if over_budget(i) => s != ItemState::Pinned,
                _ => s == ItemState::Evictable,
            };
            if may && taken.insert(&i.id) {
                out.push(Evict {
                    id: i.id.clone(),
                    why: Why::Floor,
                });
            }
        }
    }
    for i in &order {
        if over_budget(i) && state(i) != ItemState::Pinned && taken.insert(&i.id) {
            out.push(Evict {
                id: i.id.clone(),
                why: Why::CacheBudget,
            });
        }
    }
    out
}

/// Carries out PLAN on REG's runner folder. Before an eviction for the floor it re-reads DF and skips the rest of
/// those once the floor is met (or `df` fails). Before each removal it waits while IO_FULL10 is above
/// `pace_io_full_pct`, at most `pace_max_s`, then re-checks the item: one not in the register, an `unknown` one, one
/// LIVE says is in use, a slot or build dir whose lock a job holds, or one behind a link is kept and the refusal
/// recorded. Every outcome goes to LOG and is returned.
pub fn apply(
    reg: &mut Register,
    plan: &[Evict],
    live: &dyn Fn(&str) -> bool,
    df: &mut dyn FnMut() -> villa::Result<Df>,
    io_full10: &mut dyn FnMut() -> f64,
    r: &DiskRules,
    log: &mut dyn FnMut(&Evicted),
) -> Vec<Evicted> {
    let mut out = Vec::new();
    let mut floor_met = false;
    for e in plan {
        if e.why == Why::Floor {
            if floor_met {
                continue;
            }
            if !df().is_ok_and(|d| d.below_evict(r)) {
                floor_met = true;
                continue;
            }
        }
        let (kind, bytes, refused) = match reg.get(&e.id) {
            None => (
                ItemKind::Unknown,
                0,
                Some("not in the disk register".to_string()),
            ),
            Some((item, _)) if item.kind == ItemKind::Unknown => (
                item.kind,
                item.bytes,
                Some("an unknown folder: kept".to_string()),
            ),
            Some((item, rel)) => {
                pace(io_full10, r);
                let refused = if live(&e.id) {
                    Some("in use".to_string())
                } else {
                    remove(reg.root(), &item, &rel).err().map(|e| e.to_string())
                };
                (item.kind, item.bytes, refused)
            }
        };
        if refused.is_none() {
            let mut ids = vec![e.id.clone()];
            if kind == ItemKind::Slot
                && let Some(sid) = e.id.strip_prefix("slot:")
            {
                ids.push(format!("build:{sid}"));
            }
            for id in ids {
                if let Err(err) = reg.remove(&id) {
                    tracing::warn!(id, error = %err, "the disk register: an evicted item stays listed");
                }
            }
        }
        let done = Evicted {
            id: e.id.clone(),
            kind,
            bytes,
            why: e.why.clone(),
            at: epoch_s(),
            refused,
        };
        log(&done);
        out.push(done);
    }
    out
}

/// Waits while IO_FULL10 is above R's pacing threshold, in steps of at most a second, `pace_max_s` at most.
fn pace(io_full10: &mut dyn FnMut() -> f64, r: &DiskRules) {
    let max = Duration::from_secs(r.pace_max_s);
    let start = stund::now();
    while io_full10() > r.pace_io_full_pct {
        let waited = stund::now().saturating_sub(start);
        if waited >= max {
            break;
        }
        stund::sleep_blocking((max - waited).min(Duration::from_secs(1)));
    }
}

/// The slot id in REL when REL is `<parent>/<id>`.
fn slot_id<'a>(rel: &'a Path, parent: &str) -> io::Result<&'a str> {
    let mut c = rel.components();
    match (c.next(), c.next(), c.next()) {
        (Some(Component::Normal(p)), Some(Component::Normal(id)), None) if p == parent => id
            .to_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "not a slot id")),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{}: not under {parent}/", rel.display()),
        )),
    }
}

/// Removes ITEM, kept at REL under ROOT. Gone already counts as removed.
fn remove(root: &Path, item: &DiskItem, rel: &Path) -> io::Result<()> {
    let r = match item.kind {
        ItemKind::Image => remove_image(item.id.strip_prefix("image:").unwrap_or("")),
        ItemKind::Slot => remove_slot(root, slot_id(rel, "slots")?),
        ItemKind::BuildDir => remove_build_dir(root, slot_id(rel, "slots-target")?),
        _ => remove_beneath(root, rel),
    };
    match r {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        r => r,
    }
}

/// Removes `root/rel` whole. Each folder on the way is opened with `O_NOFOLLOW` (a link there fails the removal), and
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

fn slot_paths(root: &Path, id: &str) -> io::Result<SlotPaths> {
    if id.is_empty() || id.contains('/') || id == "." || id == ".." {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a slot id"));
    }
    Ok(SlotPaths {
        slot: root.join("slots").join(id),
        git_dir: root.join("slots-git").join(id),
        target: root.join("slots-target").join(id),
    })
}

/// A lock of a slot's, or "in use" when a job holds it.
fn take(
    id: &str,
    what: &str,
    l: Result<Option<super::slot::Held>>,
) -> io::Result<super::slot::Held> {
    l.map_err(|e| io::Error::other(e.to_string()))?
        .ok_or_else(|| io::Error::other(format!("slot {id}'s {what} is in use")))
}

/// A slot's checkout, git dir and build dir, under its update and target locks: a slot a job reads or builds in is kept.
fn remove_slot(root: &Path, id: &str) -> io::Result<()> {
    let p = slot_paths(root, id)?;
    let locks = Locks::of(&p);
    let _update = take(id, "checkout", locks.try_update())?;
    let _target = take(id, "build dir", locks.try_target())?;
    for d in ["slots-target", "slots", "slots-git"] {
        match remove_beneath(root, &Path::new(d).join(id)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
    }
    Ok(())
}

/// A slot's build dir, under its update and target locks: one a job reads the slot of or builds into is kept.
fn remove_build_dir(root: &Path, id: &str) -> io::Result<()> {
    let p = slot_paths(root, id)?;
    let locks = Locks::of(&p);
    let _update = take(id, "checkout", locks.try_update())?;
    let _target = take(id, "build dir", locks.try_target())?;
    remove_beneath(root, &Path::new("slots-target").join(id))
}

/// How long a podman call that only reads or removes may take.
const PODMAN_LIMIT: Duration = Duration::from_secs(120);
/// How long a pull may take: an image's layers over the runner's link.
const PULL_LIMIT: Duration = Duration::from_secs(30 * 60);

/// `podman ARGS`, stdin closed, its output captured, ended when it outlives LIMIT.
fn podman(args: &[&str], limit: Duration) -> io::Result<crate::tool::Output> {
    crate::tool::limited(Path::new("podman"), args, &[], limit).map_err(io::Error::other)
}

fn remove_image(id: &str) -> io::Result<()> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not an image id",
        ));
    }
    let out = podman(&["image", "rm", id], PODMAN_LIMIT)?;
    if out.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "podman image rm {id}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}

fn bare_id(s: &str) -> &str {
    let s = s.trim();
    s.strip_prefix("sha256:").unwrap_or(s)
}

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

/// The register's entry for image ID (podman's id, hex) pulled as REFERENCE for OWNER at NOW: `image:<id>`, named by
/// its repository, so the guard keeps the newest two per name.
pub fn image_item(id: &str, reference: &str, owner: &str, now: u64) -> DiskItem {
    let repo = reference
        .split_once('@')
        .map_or(reference, |(r, _)| r)
        .to_string();
    DiskItem {
        id: format!("image:{id}"),
        kind: ItemKind::Image,
        owner: owner.to_string(),
        machine: String::new(),
        bytes: 0,
        last_used: now,
        created: now,
        name: Some(repo),
        budget_bytes: None,
        trust: forseti::JobTrust::PrivateKeys,
    }
}

/// Pulls `reference` (checked by `check_pull`) and registers it as ours (`image_item`); returns podman's id. Jobs run
/// `--pull=never`.
pub fn pull(reg: &mut Register, reference: &str, allow: &[String], owner: &str) -> Result<String> {
    check_pull(reference, allow)?;
    let out = podman(&["pull", "-q", reference], PULL_LIMIT)?;
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
    reg.add(image_item(&id, reference, owner, epoch_s()), Path::new(""))
        .map_err(|e| io::Error::other(e.to_string()))?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::JobTrust;
    use std::cell::Cell;
    use std::fs;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    const NOW: u64 = 10_000_000;
    const DAY: u64 = 24 * 3600;

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

    fn item(id: &str, kind: ItemKind, age_s: u64) -> DiskItem {
        DiskItem {
            id: id.into(),
            kind,
            owner: "p".into(),
            machine: String::new(),
            bytes: GB,
            last_used: NOW - age_s,
            created: NOW - age_s,
            name: None,
            budget_bytes: None,
            trust: JobTrust::Private,
        }
    }

    fn cache(id: &str, trust: JobTrust, bytes: u64, age_s: u64) -> DiskItem {
        DiskItem {
            trust,
            bytes,
            budget_bytes: Some(10 * GB),
            ..item(id, ItemKind::Cache, age_s)
        }
    }

    fn image(id: &str, name: &str, created_ago: u64) -> DiskItem {
        DiskItem {
            name: Some(name.into()),
            ..item(id, ItemKind::Image, created_ago)
        }
    }

    fn ids(p: &[Evict]) -> Vec<&str> {
        p.iter().map(|e| e.id.as_str()).collect()
    }

    fn mixed() -> Vec<DiskItem> {
        vec![
            image("image:a1", "q.io/a", 10),
            cache("cache:private-old", JobTrust::Private, GB, 4 * DAY),
            item("slot:fresh", ItemKind::Slot, DAY),
            item("artifacts/j2.1", ItemKind::Artifact, 4 * DAY),
            item("jobs/run.1", ItemKind::JobFolder, 10),
            cache("cache:public-new", JobTrust::Public, GB, 10),
            image("image:a2", "q.io/a", 20),
            item("slot:stale", ItemKind::Slot, 4 * DAY),
            cache("cache:keys-huge", JobTrust::PrivateKeys, 11 * GB, 1),
            item("artifacts/j1.1", ItemKind::Artifact, 4 * DAY),
            item("jobs/done.1", ItemKind::JobFolder, 4 * DAY),
            item("build:old", ItemKind::BuildDir, 2 * DAY),
            item("build:older", ItemKind::BuildDir, 3 * DAY),
            item("build:young", ItemKind::BuildDir, 3600),
            cache("cache:public-old", JobTrust::Public, GB, 5 * DAY),
            image("image:a3", "q.io/a", 30),
            item("unknown:jobs/stray", ItemKind::Unknown, 9 * DAY),
        ]
    }

    fn pins() -> Pins {
        Pins {
            active: ["jobs/run.1".to_string()].into(),
            pinned: ["artifacts/j1.1".to_string()].into(),
            learned_at: None,
        }
    }

    // [D] pure
    #[test]
    fn below_the_floor_it_evicts_in_the_designs_order() {
        let r = DiskRules::standard();
        let p = plan(low(), 0, &mixed(), &pins(), &r, NOW);
        assert_eq!(
            ids(&p),
            [
                "jobs/done.1",
                "artifacts/j2.1",
                "build:older",
                "build:old",
                "slot:stale",
                "cache:keys-huge",
                "cache:public-old",
                "cache:private-old",
                "image:a3",
            ]
        );
        assert!(p.iter().all(|e| e.why == Why::Floor));
        // above the floor, only a cache over its budget
        let above = plan(high(), 0, &mixed(), &pins(), &r, NOW);
        assert_eq!(ids(&above), ["cache:keys-huge"]);
        assert_eq!(above[0].why, Why::CacheBudget);
    }

    /// A runner folder with one folder per id, all registered.
    fn folder(items: &[DiskItem]) -> (tempfile::TempDir, Register) {
        let t = tempfile::tempdir().unwrap();
        let mut reg = Register::open(t.path()).unwrap();
        for i in items {
            let rel = Path::new("jobs").join(i.id.replace(['/', ':'], "_"));
            fs::create_dir_all(t.path().join(&rel).join("x")).unwrap();
            reg.add(i.clone(), &rel).unwrap();
        }
        (t, reg)
    }

    fn calm() -> f64 {
        0.0
    }

    // [D] tmpfs root; a fixture df
    #[test]
    fn it_stops_once_the_floor_is_met() {
        let r = DiskRules::standard();
        let items = [
            item("jobs/a.1", ItemKind::JobFolder, 4 * DAY),
            item("jobs/b.1", ItemKind::JobFolder, 4 * DAY),
            item("jobs/c.1", ItemKind::JobFolder, 4 * DAY),
        ];
        let (t, mut reg) = folder(&items);
        let p = plan(low(), 0, &items, &Pins::default(), &r, NOW);
        assert_eq!(p.len(), 3);
        // the first removal frees enough: df reads above the floor from then on
        let mut reads = vec![high(), high(), low()];
        let done = apply(
            &mut reg,
            &p,
            &|_| false,
            &mut || Ok(reads.pop().unwrap()),
            &mut calm,
            &r,
            &mut |_| {},
        );
        assert_eq!(done.len(), 1);
        assert_eq!(done[0].refused, None);
        assert!(!t.path().join("jobs/jobs_a.1").exists());
        assert!(t.path().join("jobs/jobs_b.1/x").exists());
        assert!(t.path().join("jobs/jobs_c.1/x").exists());
        assert_eq!(reg.items().len(), 2);
        // a df that fails stops the floor's evictions too
        let again = apply(
            &mut reg,
            &p[1..],
            &|_| false,
            &mut || Err(villa::Error::io("statvfs")),
            &mut calm,
            &r,
            &mut |_| {},
        );
        assert!(again.is_empty());
    }

    // [D] pure
    #[test]
    fn images_keep_the_newest_two_per_name() {
        let r = DiskRules::standard();
        let items = [
            image("image:a1", "q.io/a", 10),
            image("image:a2", "q.io/a", 20),
            image("image:a3", "q.io/a", 30),
            image("image:a4", "q.io/a", 40),
            image("image:b1", "q.io/b", 50),
            image("image:b2", "q.io/b", 60),
            image("image:c1", "q.io/c", 70),
            DiskItem {
                name: None,
                ..item("image:loose", ItemKind::Image, 80)
            },
        ];
        let mut pinned = Pins::default();
        assert_eq!(
            ids(&plan(low(), 0, &items, &pinned, &r, NOW)),
            ["image:a4", "image:a3"],
            "the oldest of a name beyond its newest two, oldest first"
        );
        pinned.pinned.insert("image:a4".into());
        assert_eq!(ids(&plan(low(), 0, &items, &pinned, &r, NOW)), ["image:a3"]);
        pinned.active.insert("image:a3".into());
        assert!(plan(low(), 0, &items, &pinned, &r, NOW).is_empty());
        assert!(plan(high(), 0, &items, &Pins::default(), &r, NOW).is_empty());
    }

    // [D] tmpfs root
    #[test]
    fn a_cache_over_its_budget_is_trimmed_above_the_floor() {
        let r = DiskRules::standard();
        let items = [
            cache("cache:over", JobTrust::Public, 11 * GB, 10),
            cache("cache:under", JobTrust::Public, 9 * GB, 9 * DAY),
            DiskItem {
                budget_bytes: None,
                ..cache("cache:unbudgeted", JobTrust::Public, 90 * GB, 10)
            },
            cache("cache:over-pinned", JobTrust::Public, 11 * GB, 10),
        ];
        let pins = Pins {
            pinned: ["cache:over-pinned".to_string()].into(),
            ..Pins::default()
        };
        let p = plan(high(), 0, &items, &pins, &r, NOW);
        assert_eq!(
            p,
            [Evict {
                id: "cache:over".into(),
                why: Why::CacheBudget
            }]
        );
        let (t, mut reg) = folder(&items);
        // a budget trim does not ask df: it goes above the floor too
        let done = apply(
            &mut reg,
            &p,
            &|_| false,
            &mut || panic!("df is not read for a budget trim"),
            &mut calm,
            &r,
            &mut |_| {},
        );
        assert_eq!(done.len(), 1);
        assert_eq!(done[0].refused, None);
        assert!(!t.path().join("jobs/cache_over").exists());
        assert!(t.path().join("jobs/cache_under/x").exists());
    }

    // [D] pure (RF2)
    #[test]
    fn the_owners_quota_evicts_a_pin_but_never_an_active_item() {
        let r = DiskRules {
            quota_gb: Some(2),
            ..DiskRules::standard()
        };
        let items = [
            item("jobs/running.1", ItemKind::JobFolder, 4 * DAY),
            item("jobs/pinned.1", ItemKind::JobFolder, 10),
            item("build:young", ItemKind::BuildDir, 10),
            item("slot:s", ItemKind::Slot, 10),
        ];
        let pins = Pins {
            active: ["jobs/running.1".to_string()].into(),
            pinned: ["jobs/pinned.1".to_string()].into(),
            learned_at: None,
        };
        // 4 GB kept, a 2 GB quota: two items go, in the order, the pin among them; the running job's never
        let p = plan(high(), 4 * GB, &items, &pins, &r, NOW);
        assert_eq!(ids(&p), ["jobs/pinned.1", "build:young"]);
        assert!(p.iter().all(|e| e.why == Why::Quota));
        // whatever is over: never the active item
        let all = plan(low(), 100 * GB, &items, &pins, &r, NOW);
        assert!(!ids(&all).contains(&"jobs/running.1"), "{all:?}");
        assert_eq!(all.len(), 3);
        // under the quota and above the floor: nothing
        assert!(plan(high(), 2 * GB, &items, &pins, &r, NOW).is_empty());
    }

    // [D] tmpfs root, real flocks (RF1)
    #[test]
    fn a_held_slot_is_never_evicted_even_when_ordered() {
        let r = DiskRules::standard();
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        let mut reg = Register::open(root).unwrap();
        for sid in ["read", "built", "live", "free"] {
            for d in ["slots", "slots-git", "slots-target"] {
                fs::create_dir_all(root.join(d).join(sid).join("x")).unwrap();
            }
            reg.add(
                item(&format!("slot:{sid}"), ItemKind::Slot, 9 * DAY),
                &Path::new("slots").join(sid),
            )
            .unwrap();
            reg.add(
                item(&format!("build:{sid}"), ItemKind::BuildDir, 9 * DAY),
                &Path::new("slots-target").join(sid),
            )
            .unwrap();
        }
        let p = |sid: &str| slot_paths(root, sid).unwrap();
        let reader = Locks::of(&p("read")).read().unwrap();
        let builder = Locks::of(&p("built")).target().unwrap();
        let order: Vec<Evict> = ["read", "built", "live", "free"]
            .iter()
            .flat_map(|sid| {
                [
                    Evict {
                        id: format!("build:{sid}"),
                        why: Why::Ordered("test".into()),
                    },
                    Evict {
                        id: format!("slot:{sid}"),
                        why: Why::Ordered("test".into()),
                    },
                ]
            })
            .collect();
        let mut logged = Vec::new();
        let done = apply(
            &mut reg,
            &order,
            &|id| id.ends_with(":live"),
            &mut || Ok(low()),
            &mut calm,
            &r,
            &mut |e| logged.push(e.clone()),
        );
        drop((reader, builder));
        assert_eq!(done, logged, "every outcome is logged");
        let kept: Vec<&str> = done
            .iter()
            .filter(|e| e.refused.is_some())
            .map(|e| e.id.as_str())
            .collect();
        assert_eq!(
            kept,
            [
                "build:read",
                "slot:read",
                "build:built",
                "slot:built",
                "build:live",
                "slot:live"
            ]
        );
        for sid in ["read", "built", "live"] {
            for d in ["slots", "slots-git", "slots-target"] {
                assert!(root.join(d).join(sid).join("x").exists(), "{d}/{sid}");
            }
        }
        for d in ["slots", "slots-git", "slots-target"] {
            assert!(!root.join(d).join("free").exists(), "{d}/free");
        }
        assert!(reg.get("slot:free").is_none() && reg.get("build:free").is_none());
        assert!(reg.get("slot:read").is_some());
    }

    // [D] tmpfs root
    #[test]
    fn an_item_behind_a_symlink_or_outside_the_root_is_never_removed() {
        let r = DiskRules::standard();
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        let outside = t.path().join("outside");
        fs::create_dir_all(outside.join("x")).unwrap();
        crate::fsio::write(outside.join("sentinel"), "keep\n").unwrap();
        crate::fsio::write(outside.join("x/sentinel"), "keep\n").unwrap();
        fs::create_dir_all(root.join("jobs/a.1")).unwrap();
        // links a job could leave in its folder: removed as links, never followed
        std::os::unix::fs::symlink(&outside, root.join("jobs/a.1/dir-link")).unwrap();
        std::os::unix::fs::symlink(outside.join("sentinel"), root.join("jobs/a.1/file-link"))
            .unwrap();
        // a link where the runner's own folder belongs
        std::os::unix::fs::symlink(&outside, root.join("artifacts")).unwrap();
        let mut reg = Register::open(&root).unwrap();
        reg.add(
            item("jobs/a.1", ItemKind::JobFolder, 9 * DAY),
            Path::new("jobs/a.1"),
        )
        .unwrap();
        reg.add(
            item("artifacts/x", ItemKind::Artifact, 9 * DAY),
            Path::new("artifacts/x"),
        )
        .unwrap();
        reg.add(
            item("slot:x", ItemKind::Slot, 9 * DAY),
            Path::new("slots/x"),
        )
        .unwrap();
        // a register edited by hand to name paths outside the folder: the guard refuses them as it finds them
        let text = crate::fsio::read_to_string(root.join(super::super::register::FILE)).unwrap();
        let text = text.replacen("\"slots/x\"", "\"../outside/x\"", 1);
        crate::fsio::write(root.join(super::super::register::FILE), text).unwrap();
        let mut reg = Register::open(&root).unwrap();
        let mut hand = reg.get("slot:x").unwrap().0;
        hand.id = "abs".into();
        hand.kind = ItemKind::Output;
        let text = crate::fsio::read_to_string(root.join(super::super::register::FILE)).unwrap();
        let entry = serde_json::json!({"item": hand, "rel": outside.join("x")});
        let mut v: serde_json::Value = serde_json::from_str(&text).unwrap();
        v["items"].as_array_mut().unwrap().push(entry);
        crate::fsio::write(root.join(super::super::register::FILE), v.to_string()).unwrap();
        reg = Register::open(&root).unwrap();

        let order: Vec<Evict> = ["jobs/a.1", "artifacts/x", "slot:x", "abs"]
            .iter()
            .map(|id| Evict {
                id: id.to_string(),
                why: Why::Floor,
            })
            .collect();
        let done = apply(
            &mut reg,
            &order,
            &|_| false,
            &mut || Ok(low()),
            &mut calm,
            &r,
            &mut |_| {},
        );
        let refused: Vec<&str> = done
            .iter()
            .filter(|e| e.refused.is_some())
            .map(|e| e.id.as_str())
            .collect();
        assert_eq!(refused, ["artifacts/x", "slot:x", "abs"], "{done:?}");
        assert!(!root.join("jobs/a.1").exists(), "the job folder goes");
        assert_eq!(
            crate::fsio::read_to_string(outside.join("sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(
            crate::fsio::read_to_string(outside.join("x/sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(fs::read_dir(&outside).unwrap().count(), 2);
    }

    /// A clock whose sleeps pass at once and move it by their length.
    struct Fast(AtomicU64);

    impl stund::Provider for Fast {
        fn sleep(
            &self,
            d: Duration,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
            self.0.fetch_add(d.as_millis() as u64, Ordering::SeqCst);
            Box::pin(std::future::ready(()))
        }
        fn now(&self) -> Duration {
            Duration::from_millis(self.0.load(Ordering::SeqCst))
        }
    }

    // [D] tmpfs root, a fixture PSI, a test clock
    #[test]
    fn removal_waits_on_io_pressure_at_most_60s() {
        let r = DiskRules::standard();
        let clock = Arc::new(Fast(AtomicU64::new(0)));
        let _c = stund::on_this_thread(clock.clone());
        let items = [
            item("jobs/a.1", ItemKind::JobFolder, 9 * DAY),
            item("jobs/b.1", ItemKind::JobFolder, 9 * DAY),
        ];
        let (t, mut reg) = folder(&items);
        // IO stays at 90 %: the removal waits 60 s, then goes
        let reads = Cell::new(0);
        let mut hot = || {
            reads.set(reads.get() + 1);
            90.0
        };
        let p = plan(low(), 0, &items[..1], &Pins::default(), &r, NOW);
        let done = apply(
            &mut reg,
            &p,
            &|_| false,
            &mut || Ok(low()),
            &mut hot,
            &r,
            &mut |_| {},
        );
        assert_eq!(done[0].refused, None);
        assert_eq!(stund::now(), Duration::from_secs(60));
        assert_eq!(reads.get(), 61);
        assert!(!t.path().join("jobs/jobs_a.1").exists());
        // IO calms after 3 s: the removal goes then
        let mut io = [10.0, 30.0, 30.0, 30.0].to_vec();
        let p = plan(low(), 0, &items[1..], &Pins::default(), &r, NOW);
        apply(
            &mut reg,
            &p,
            &|_| false,
            &mut || Ok(low()),
            &mut || io.pop().unwrap(),
            &r,
            &mut |_| {},
        );
        assert_eq!(stund::now(), Duration::from_secs(63));
        assert!(!t.path().join("jobs/jobs_b.1").exists());
    }

    // [D] tmpfs root
    #[test]
    fn an_unknown_item_is_never_removed_even_when_ordered() {
        let r = DiskRules::standard();
        let t = tempfile::tempdir().unwrap();
        fs::create_dir_all(t.path().join("jobs/stray/x")).unwrap();
        let mut reg = Register::open(t.path()).unwrap();
        assert_eq!(reg.reconcile().len(), 1);
        let order = [Evict {
            id: "unknown:jobs/stray".into(),
            why: Why::Ordered("test".into()),
        }];
        let done = apply(
            &mut reg,
            &order,
            &|_| false,
            &mut || Ok(low()),
            &mut calm,
            &r,
            &mut |_| {},
        );
        assert!(done[0].refused.is_some());
        assert!(t.path().join("jobs/stray/x").exists());
        assert!(
            plan(
                low(),
                1 << 50,
                &reg.items(),
                &Pins::default(),
                &DiskRules {
                    quota_gb: Some(0),
                    ..r
                },
                NOW + 99 * DAY
            )
            .is_empty()
        );
    }

    // [D] pure: an image artifact's pull of a repository the project's list lacks is refused, naming the list
    #[test]
    fn a_pull_outside_the_allow_list_is_refused() {
        let d = "b".repeat(64);
        let e = check_pull(
            &format!("evil.example/x@sha256:{d}"),
            &["good.example/x".to_string()],
        )
        .unwrap_err();
        assert!(e.to_string().contains("allow-list"), "{e}");
        assert!(
            check_pull(&format!("good.example/x@sha256:{d}"), &[]).is_err(),
            "an empty list allows nothing"
        );
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
        let i = image_item("ab12", &format!("q.io/x@sha256:{d}"), "p", 5);
        assert_eq!(
            (i.id.as_str(), i.name.as_deref()),
            ("image:ab12", Some("q.io/x"))
        );
    }
}
