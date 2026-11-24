//! The runner's disk register (editing-model design §4.8): one entry per item drgnx made under the runner folder, so the
//! guard reads what it may remove from here, never from path patterns (docs/develop/sleipnir.md, "Disk and caches").
//!
//! `<root>/register.json` holds `{"version": 1, "items": [{"item": DiskItem, "rel": PATH}, …]}`. Every change is made
//! under `<root>/register.lock` (an `flock`, so `serve` and other processes of the runner take turns): the file is read
//! again, changed, and written whole as a new file renamed over the old one, so a crash mid-write leaves the old
//! register. A register that does not parse is an error, never an empty register.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use forseti::disk::{DiskItem, ItemKind};
use rustix::fs::FlockOperation;
use serde::{Deserialize, Serialize};

/// The register's file under the runner folder.
pub const FILE: &str = "register.json";
const LOCK: &str = "register.lock";
const VERSION: u32 = 1;

/// The folders under the runner folder whose children are items, and the cache folders' depth below `cache/`
/// (`cache/<project>/<trust>/<name>`). A child of one of these that the register does not know is `unknown`.
const ITEM_PARENTS: [&str; 6] = [
    "jobs",
    "artifacts",
    "outputs",
    "slots",
    "slots-git",
    "slots-target",
];
const CACHE_DEPTH: usize = 3;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct Entry {
    item: DiskItem,
    /// Its path under the runner folder; empty for an image (it lives in podman's store).
    rel: PathBuf,
    /// The `measure` round that last sized it (0: never).
    #[serde(default)]
    measured: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct OnDisk {
    version: u32,
    #[serde(default)]
    round: u64,
    items: Vec<Entry>,
}

/// The register of runner folder `root`.
pub struct Register {
    root: PathBuf,
    entries: BTreeMap<String, Entry>,
    round: u64,
    gone: Vec<String>,
}

fn io_err(what: &str, e: io::Error) -> villa::Error {
    villa::Error::io(format!("the disk register: {what}: {e}")).with_source(e)
}

/// REL is a plain relative path (no `..`, no root, not empty).
fn plain(rel: &Path) -> bool {
    rel.components().next().is_some() && rel.components().all(|c| matches!(c, Component::Normal(_)))
}

impl Register {
    /// The register of ROOT as on disk (none yet: empty).
    pub fn open(root: &Path) -> villa::Result<Register> {
        let mut r = Register {
            root: root.to_path_buf(),
            entries: BTreeMap::new(),
            round: 0,
            gone: Vec::new(),
        };
        r.load()?;
        Ok(r)
    }

    fn load(&mut self) -> villa::Result<()> {
        let text = match crate::fsio::read_to_string(self.root.join(FILE)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.entries.clear();
                return Ok(());
            }
            r => r.map_err(|e| io_err("read", e))?,
        };
        let d: OnDisk = serde_json::from_str(&text).map_err(|e| {
            villa::Error::invalid(format!("the disk register {FILE} does not parse: {e}"))
        })?;
        if d.version != VERSION {
            return Err(villa::Error::invalid(format!(
                "the disk register is version {}, not {VERSION}",
                d.version
            )));
        }
        self.round = d.round;
        self.entries = d
            .items
            .into_iter()
            .map(|e| (e.item.id.clone(), e))
            .collect();
        Ok(())
    }

    fn save(&self) -> villa::Result<()> {
        let d = OnDisk {
            version: VERSION,
            round: self.round,
            items: self.entries.values().cloned().collect(),
        };
        let text = serde_json::to_vec_pretty(&d)
            .map_err(|e| villa::Error::internal(format!("the disk register: {e}")))?;
        crate::fsio::write(self.root.join(FILE), text).map_err(|e| io_err("write", e))
    }

    /// F on the register read again from disk, written back after, all under the register's lock.
    fn change<T>(&mut self, f: impl FnOnce(&mut Register) -> villa::Result<T>) -> villa::Result<T> {
        fs::create_dir_all(&self.root).map_err(|e| io_err("the runner folder", e))?;
        let lock = crate::fsio::open_lock(self.root.join(LOCK), 0o600)
            .map_err(|e| io_err("its lock", e))?;
        rustix::fs::flock(&lock, FlockOperation::LockExclusive)
            .map_err(|e| io_err("its lock", e.into()))?;
        self.load()?;
        let out = f(self)?;
        self.save()?;
        Ok(out)
    }

    /// ITEM, kept at REL under the runner folder (an image: an empty REL). A REL that is not a plain relative path is
    /// refused. An item already there keeps its creation time.
    pub fn add(&mut self, item: DiskItem, rel: &Path) -> villa::Result<()> {
        let image = item.kind == ItemKind::Image;
        if image != rel.as_os_str().is_empty() || (!image && !plain(rel)) {
            return Err(villa::Error::refused(format!(
                "{}: not a plain path under the runner folder",
                rel.display()
            )));
        }
        self.change(|r| {
            let mut item = item;
            if let Some(old) = r.entries.get(&item.id) {
                item.created = old.item.created;
                item.bytes = item.bytes.max(old.item.bytes);
            }
            let measured = r.entries.get(&item.id).map_or(0, |e| e.measured);
            r.entries.insert(
                item.id.clone(),
                Entry {
                    item,
                    rel: rel.to_path_buf(),
                    measured,
                },
            );
            Ok(())
        })
    }

    /// Item ID was used at NOW.
    pub fn touch(&mut self, id: &str, now: u64) -> villa::Result<()> {
        self.change(|r| match r.entries.get_mut(id) {
            Some(e) => {
                e.item.last_used = e.item.last_used.max(now);
                Ok(())
            }
            None => Err(villa::Error::not_found(format!(
                "{id} is not in the disk register"
            ))),
        })
    }

    /// Item ID is gone from the register (its bytes were removed, or it was never there).
    pub fn remove(&mut self, id: &str) -> villa::Result<()> {
        self.change(|r| {
            r.entries.remove(id);
            Ok(())
        })
    }

    /// Every item, by id.
    pub fn items(&self) -> Vec<DiskItem> {
        self.entries.values().map(|e| e.item.clone()).collect()
    }

    /// Item ID and its path under the runner folder.
    pub fn get(&self, id: &str) -> Option<(DiskItem, PathBuf)> {
        self.entries
            .get(id)
            .map(|e| (e.item.clone(), e.rel.clone()))
    }

    /// The runner folder.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The items removed from the register by `reconcile` since the last call (their folders were gone).
    pub fn take_gone(&mut self) -> Vec<String> {
        std::mem::take(&mut self.gone)
    }

    /// Sizes items, the least recently sized first, until BUDGET has passed on the installed clock (`stund::now`): each
    /// by a walk that adds up `st_blocks` and never follows a link (never `du`). Returns how many it sized.
    pub fn measure(&mut self, budget: Duration) -> usize {
        let start = stund::now();
        let mut order: Vec<(u64, String, PathBuf)> = self
            .entries
            .values()
            .filter(|e| !e.rel.as_os_str().is_empty())
            .map(|e| (e.measured, e.item.id.clone(), e.rel.clone()))
            .collect();
        order.sort();
        let mut sized: Vec<(String, u64)> = Vec::new();
        for (_, id, rel) in order {
            if stund::now().saturating_sub(start) >= budget {
                break;
            }
            sized.push((id, blocks_bytes(&self.root.join(rel))));
        }
        let n = sized.len();
        if n == 0 {
            return 0;
        }
        let done = self.change(|r| {
            r.round += 1;
            let round = r.round;
            for (id, bytes) in sized {
                if let Some(e) = r.entries.get_mut(&id) {
                    e.item.bytes = bytes;
                    e.measured = round;
                }
            }
            Ok(())
        });
        if let Err(e) = done {
            tracing::warn!(error = %e, "the disk register: sizes not kept");
        }
        n
    }

    /// The folders under the runner folder where items live that the register does not know: each is added as an
    /// `unknown` item (reported and kept: only the one-time prune removes those) and returned. Items whose folder is
    /// gone leave the register ([`Register::take_gone`]). A link is never followed or listed.
    pub fn reconcile(&mut self) -> Vec<PathBuf> {
        let now = epoch_s();
        let machine = String::new();
        let mut found: Vec<PathBuf> = Vec::new();
        for p in ITEM_PARENTS {
            found.extend(children(&self.root, Path::new(p)));
        }
        let mut caches = vec![PathBuf::from("cache")];
        for _ in 0..CACHE_DEPTH {
            caches = caches
                .iter()
                .flat_map(|c| children(&self.root, c))
                .collect();
        }
        found.extend(caches);
        let root = self.root.clone();
        let r = self.change(move |r| {
            let known: std::collections::BTreeSet<PathBuf> = r
                .entries
                .values()
                .filter(|e| e.item.kind != ItemKind::Unknown)
                .flat_map(|e| covered(&e.item, &e.rel))
                .collect();
            let gone: Vec<String> = r
                .entries
                .values()
                .filter(|e| {
                    !e.rel.as_os_str().is_empty()
                        && e.item.kind != ItemKind::Unknown
                        && fs::symlink_metadata(root.join(&e.rel)).is_err()
                })
                .map(|e| e.item.id.clone())
                .collect();
            for id in &gone {
                r.entries.remove(id);
            }
            // an unknown folder someone removed since leaves too
            let stale: Vec<String> = r
                .entries
                .values()
                .filter(|e| {
                    e.item.kind == ItemKind::Unknown
                        && fs::symlink_metadata(root.join(&e.rel)).is_err()
                })
                .map(|e| e.item.id.clone())
                .collect();
            for id in &stale {
                r.entries.remove(id);
            }
            let mut unknown = Vec::new();
            for rel in found {
                if known.contains(&rel) {
                    continue;
                }
                let id = format!("unknown:{}", rel.display());
                r.entries.entry(id.clone()).or_insert_with(|| Entry {
                    item: DiskItem {
                        id,
                        kind: ItemKind::Unknown,
                        owner: String::new(),
                        machine: machine.clone(),
                        bytes: 0,
                        last_used: now,
                        created: now,
                        name: None,
                        budget_bytes: None,
                        trust: forseti::JobTrust::PrivateKeys,
                    },
                    rel: rel.clone(),
                    measured: 0,
                });
                unknown.push(rel);
            }
            Ok((gone, unknown))
        });
        match r {
            Ok((gone, unknown)) => {
                self.gone.extend(gone);
                unknown
            }
            Err(e) => {
                tracing::warn!(error = %e, "the disk register: not reconciled");
                vec![]
            }
        }
    }
}

/// Now in epoch seconds, on the installed clock.
pub fn epoch_s() -> u64 {
    stund::wall()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The folders an item stands for: a slot is its checkout and its git dir.
fn covered(item: &DiskItem, rel: &Path) -> Vec<PathBuf> {
    let mut out = vec![rel.to_path_buf()];
    if item.kind == ItemKind::Slot
        && let Ok(id) = rel.strip_prefix("slots")
    {
        out.push(Path::new("slots-git").join(id));
    }
    out
}

/// The real folders (never links) in ROOT/REL, as paths under ROOT; none when it isn't there.
fn children(root: &Path, rel: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(root.join(rel)) else {
        return vec![];
    };
    let mut out: Vec<PathBuf> = rd
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| rel.join(e.file_name()))
        .collect();
    out.sort();
    out
}

/// The bytes PATH takes on the disk: `st_blocks` × 512 of it and everything under it, no link followed.
pub fn blocks_bytes(path: &Path) -> u64 {
    let Ok(m) = fs::symlink_metadata(path) else {
        return 0;
    };
    let own = m.blocks() * 512;
    if !m.is_dir() {
        return own;
    }
    let Ok(rd) = fs::read_dir(path) else {
        return own;
    };
    own + rd.flatten().map(|e| blocks_bytes(&e.path())).sum::<u64>()
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::JobTrust;
    use std::sync::atomic::{AtomicU64, Ordering};

    pub(crate) fn item(id: &str, kind: ItemKind) -> DiskItem {
        DiskItem {
            id: id.into(),
            kind,
            owner: "alpha".into(),
            machine: "m".into(),
            bytes: 0,
            last_used: 100,
            created: 100,
            name: None,
            budget_bytes: None,
            trust: JobTrust::Private,
        }
    }

    /// [D] a crash mid-write leaves a temporary file beside the register: the register read is the old one, whole; a
    /// register that does not parse is an error, never an empty register.
    #[test]
    fn the_register_survives_a_crash_mid_write() {
        let t = tempfile::tempdir().unwrap();
        let mut r = Register::open(t.path()).unwrap();
        r.add(item("jobs/a.1", ItemKind::JobFolder), Path::new("jobs/a.1"))
            .unwrap();
        r.add(item("slot:s1", ItemKind::Slot), Path::new("slots/s1"))
            .unwrap();
        let whole = crate::fsio::read_to_string(t.path().join(FILE)).unwrap();
        // the half-written next version, as a crash between the write and the rename leaves it
        let half = &whole[..whole.len() / 2];
        crate::fsio::write(t.path().join(format!(".{FILE}.tmp")), half).unwrap();
        let again = Register::open(t.path()).unwrap();
        assert_eq!(again.items(), r.items());
        assert_eq!(again.items().len(), 2);
        // and a torn register itself is refused, not read as empty
        crate::fsio::write(t.path().join(FILE), half).unwrap();
        assert!(Register::open(t.path()).is_err());
    }

    /// [D] an item's path is checked: only a plain path under the runner folder; an image has none.
    #[test]
    fn an_item_path_must_stay_under_the_root() {
        let t = tempfile::tempdir().unwrap();
        let mut r = Register::open(t.path()).unwrap();
        for bad in ["/etc", "../x", "jobs/../../x", ""] {
            assert!(
                r.add(item("x", ItemKind::JobFolder), Path::new(bad))
                    .is_err(),
                "{bad}"
            );
        }
        assert!(
            r.add(item("i", ItemKind::Image), Path::new("images/x"))
                .is_err()
        );
        r.add(item("image:abc", ItemKind::Image), Path::new(""))
            .unwrap();
        r.add(item("jobs/b.1", ItemKind::JobFolder), Path::new("jobs/b.1"))
            .unwrap();
        r.touch("jobs/b.1", 500).unwrap();
        assert_eq!(r.get("jobs/b.1").unwrap().0.last_used, 500);
        assert!(r.touch("nope", 1).is_err());
        r.remove("jobs/b.1").unwrap();
        assert!(r.get("jobs/b.1").is_none());
    }

    /// [D] a folder where items live that nothing registered is reported `unknown` and kept; a registered item whose
    /// folder is gone leaves the register.
    #[test]
    fn an_unregistered_dir_is_reported_unknown_and_kept() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        for d in [
            "jobs/known.1",
            "jobs/stray.1",
            "slots/s1",
            "slots-git/s1",
            "cache/p/public/cargo",
            "bin/v1",
        ] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        std::os::unix::fs::symlink(t.path(), root.join("jobs/link")).unwrap();
        let mut r = Register::open(root).unwrap();
        r.add(
            item("jobs/known.1", ItemKind::JobFolder),
            Path::new("jobs/known.1"),
        )
        .unwrap();
        r.add(item("slot:s1", ItemKind::Slot), Path::new("slots/s1"))
            .unwrap();
        r.add(
            item("jobs/went.1", ItemKind::JobFolder),
            Path::new("jobs/went.1"),
        )
        .unwrap();
        let unknown = r.reconcile();
        assert_eq!(
            unknown,
            [
                PathBuf::from("jobs/stray.1"),
                PathBuf::from("cache/p/public/cargo")
            ]
        );
        assert_eq!(r.take_gone(), ["jobs/went.1"]);
        let (u, rel) = r.get("unknown:jobs/stray.1").unwrap();
        assert_eq!(
            (u.kind, rel),
            (ItemKind::Unknown, PathBuf::from("jobs/stray.1"))
        );
        assert!(root.join("jobs/stray.1").exists(), "kept");
        // a second pass reports it again and adds nothing new
        assert_eq!(r.reconcile().len(), 2);
        assert_eq!(r.items().len(), 4);
    }

    /// A clock that moves 1 s at every reading.
    struct Ticking(AtomicU64);

    impl stund::Provider for Ticking {
        fn sleep(
            &self,
            _d: Duration,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
            Box::pin(std::future::ready(()))
        }
        fn now(&self) -> Duration {
            Duration::from_secs(self.0.fetch_add(1, Ordering::SeqCst))
        }
    }

    /// [D] sizes come from `st_blocks`, lazily: a round stops at its budget and the next starts with the items not
    /// yet sized; a link is never followed.
    #[test]
    fn measure_sizes_lazily_by_blocks() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        let mut r = Register::open(root).unwrap();
        for n in ["a", "b", "c"] {
            let rel = format!("jobs/{n}.1");
            fs::create_dir_all(root.join(&rel)).unwrap();
            crate::fsio::write(root.join(&rel).join("f"), vec![7u8; 64 << 10]).unwrap();
            r.add(item(&rel, ItemKind::JobFolder), Path::new(&rel))
                .unwrap();
        }
        std::os::unix::fs::symlink("/usr", root.join("jobs/a.1/out")).unwrap();
        // each reading moves 1 s: a 2 s budget sizes the first item only (start, then one check passes)
        let _clock = stund::on_this_thread(std::sync::Arc::new(Ticking(AtomicU64::new(0))));
        assert_eq!(r.measure(Duration::from_secs(2)), 1);
        assert_eq!(r.measure(Duration::from_secs(100)), 3);
        for i in r.items() {
            assert!(
                i.bytes >= 64 << 10 && i.bytes < 1 << 20,
                "{}: {}",
                i.id,
                i.bytes
            );
        }
    }
}
