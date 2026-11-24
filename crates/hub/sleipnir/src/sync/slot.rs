//! Checkout slots (docs/develop/sleipnir.md, "Sync").
//!
//! One stable directory per slot key, updated in place. Its git dir and its target dir are siblings, never inside it:
//!
//! - `<root>/slots/<id>/`: the checkout, which jobs see read-only;
//! - `<root>/slots-git/<id>/`: its git dir (index, config, locks), borrowing objects from the mirror;
//! - `<root>/slots-target/<id>/`: its `CARGO_TARGET_DIR`.
//!
//! An update first deletes, never follows, every `.git` in the slot. It then builds the wanted index (the commit
//! plus the overlay) in a temporary index and moves the checkout to it with `read-tree --reset -u`: git rewrites only
//! the files whose content changed, with the current time, removes deletions, and leaves every other file and its
//! mtime alone. No hook, fsmonitor or config a job could have written is ever read (`super::git`).

use std::fs;
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use forseti::JobTrust;
use forseti::disk::{DiskItem, ItemKind};
use rustix::fs::FlockOperation;
use sha2::{Digest, Sha256};

use super::capture::{Entry, Inputs, MODE_EXEC, MODE_FILE, MODE_LINK};
use super::git::{Git, line, run, spawn};
use super::register::Register;
use super::{Result, SyncError, check_path, hex, refused};

/// What a slot family is shared by: jobs of one project, trust, toolchain, cone and role. Not the worktree: two
/// worktrees of one project share a family, and each of its instances ([`lease`]) is held at one tree's inputs.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SlotFamily {
    pub project: String,
    pub trust: JobTrust,
    /// The toolchain's identity; empty until toolchains are images by digest.
    pub toolchain: String,
    /// The part of the tree the slot holds; empty: all of it.
    pub cone: String,
    /// An author's run or a gate's: a gate never takes an author's slot or build dir.
    pub role: forseti::Role,
}

/// Where one slot instance's three directories are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlotPaths {
    pub slot: PathBuf,
    pub git_dir: PathBuf,
    pub target: PathBuf,
}

/// Where the overlay's file bytes are: one file per sha256, whose bytes hash to it (a link's are its target).
pub trait Blobs {
    fn path(&self, sha256: &[u8; 32]) -> PathBuf;
}

/// The uncommitted part of a job's inputs, and where its bytes are.
pub struct Overlay<'a> {
    pub entries: &'a [Entry],
    pub extras: &'a [Entry],
    pub blobs: &'a dyn Blobs,
}

impl<'a> Overlay<'a> {
    pub fn of(inputs: &'a Inputs, blobs: &'a dyn Blobs) -> Overlay<'a> {
        Overlay {
            entries: &inputs.manifest,
            extras: &inputs.extras,
            blobs,
        }
    }
}

/// How a private copy was made.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyKind {
    /// Every file shares its blocks with the slot's (the filesystem clones).
    Reflink,
    /// At least one file was copied byte by byte (the filesystem can't clone).
    Plain,
}

impl SlotFamily {
    /// The slot key of a job: its project, trust and role; one toolchain and the whole tree for now. The runner names
    /// its slots by it, and the hub knows from it whether a runner's `ready` lists the job's slot family.
    pub fn of(spec: &forseti::JobSpec) -> SlotFamily {
        SlotFamily {
            project: spec.project.as_str().to_string(),
            trust: spec.trust,
            toolchain: String::new(),
            cone: String::new(),
            role: spec.role,
        }
    }

    /// The family's id: 32 hex digits of sha256 over the five words (the trust as the design's word), each
    /// length-prefixed.
    pub fn id(&self) -> String {
        let mut h = Sha256::new();
        for w in [
            self.project.as_str(),
            trust_word(self.trust),
            self.toolchain.as_str(),
            self.cone.as_str(),
            self.role.name(),
        ] {
            h.update((w.len() as u64).to_le_bytes());
            h.update(w.as_bytes());
        }
        hex(&h.finalize()[..16])
    }

    /// Instance N's name: the family's id and the number, `<id>-<n>` (the directory name, the register's `slot:` and
    /// `build:` ids).
    pub fn instance_id(&self, n: u32) -> String {
        format!("{}-{n}", self.id())
    }
}

/// The family id and instance number of the instance named NAME (`<id>-<n>`).
pub fn split_instance(name: &str) -> Option<(&str, u32)> {
    let (family, n) = name.rsplit_once('-')?;
    (family.len() == 32 && family.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| n.parse().ok().map(|n| (family, n)))
        .flatten()
}

/// The job trust's word: `public`, `private` or `private+keys`.
pub(crate) fn trust_word(t: JobTrust) -> &'static str {
    match t {
        JobTrust::Public => "public",
        JobTrust::Private => "private",
        JobTrust::PrivateKeys => "private+keys",
    }
}

/// The ids of the slot families under the runner folder `root`, sorted, each once (what `ready` lists as present).
pub fn present(root: &Path) -> Vec<String> {
    let mut ids: Vec<String> = fs::read_dir(root.join("slots"))
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .filter_map(|e| e.file_name().into_string().ok())
                .filter_map(|n| split_instance(&n).map(|(family, _)| family.to_string()))
                .collect()
        })
        .unwrap_or_default();
    ids.sort();
    ids.dedup();
    ids
}

/// Instance N of KEY's family: its directories under the runner folder `root`.
pub fn paths(root: &Path, key: &SlotFamily, n: u32) -> SlotPaths {
    paths_of(root, &key.instance_id(n))
}

/// The directories of the instance named ID (`<family>-<n>`).
pub fn paths_of(root: &Path, id: &str) -> SlotPaths {
    SlotPaths {
        slot: root.join("slots").join(id),
        git_dir: root.join("slots-git").join(id),
        target: root.join("slots-target").join(id),
    }
}

/// One leased-before instance of a family: its number, the worktree that last leased it and when it was last used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlotInstance {
    pub n: u32,
    pub worktree: Option<PathBuf>,
    /// Epoch seconds of its `used` mark.
    pub last_used: u64,
}

/// The slot limit: as many instances as the free disk above the evict floor holds at their p95 size (a slot and its
/// build dir), at least 2 and at most MAX_SLOTS (the runner's setting, 16 by default). A size of 0 (nothing measured
/// yet) counts as [`MIN_INSTANCE_BYTES`], so a fresh runner does not read an unlimited disk.
pub fn slot_limit(
    free_above_floor: u64,
    slot_bytes_p95: u64,
    build_bytes_p95: u64,
    max_slots: u32,
) -> u32 {
    let each = slot_bytes_p95
        .saturating_add(build_bytes_p95)
        .max(MIN_INSTANCE_BYTES);
    let n = u32::try_from(free_above_floor / each).unwrap_or(u32::MAX);
    n.max(2).min(max_slots)
}

/// What an instance counts as when nothing has been measured, bytes.
pub const MIN_INSTANCE_BYTES: u64 = 1 << 30;

/// The default of the runner's `max-slots`.
pub const DEFAULT_MAX_SLOTS: u32 = 16;

/// The instance to reuse among the FREE ones: the one WORKTREE last leased, else the least recently used (the lowest
/// number among equals); an index into FREE, none when it is empty.
pub fn pick_instance(free: &[SlotInstance], worktree: Option<&Path>) -> Option<usize> {
    if let Some(w) = worktree
        && let Some(i) = free.iter().position(|f| f.worktree.as_deref() == Some(w))
    {
        return Some(i);
    }
    free.iter()
        .enumerate()
        .min_by_key(|(_, f)| (f.last_used, f.n))
        .map(|(i, _)| i)
}

/// What an instance's lease is: its number and directories, and the read lock that keeps it at its inputs.
pub struct Lease {
    pub n: u32,
    pub paths: SlotPaths,
    pub held: Held,
}

/// The instances KEY's family has under ROOT, by number.
pub fn instances(root: &Path, key: &SlotFamily) -> Vec<SlotInstance> {
    let family = key.id();
    let mut out: Vec<SlotInstance> = fs::read_dir(root.join("slots-git"))
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| {
                    let name = e.file_name().into_string().ok()?;
                    let (f, n) = split_instance(&name)?;
                    (f == family).then_some((n, e.path()))
                })
                .map(|(n, dir)| SlotInstance {
                    n,
                    worktree: crate::fsio::read_to_string(dir.join(WORKTREE))
                        .ok()
                        .map(PathBuf::from),
                    last_used: fs::metadata(dir.join("used"))
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map_or(0, |d| d.as_secs()),
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by_key(|i| i.n);
    out
}

/// The file in an instance's git dir that names the worktree that last leased it.
const WORKTREE: &str = "worktree";

/// A read lock on an instance of KEY's family held at INPUTS, for a job from WORKTREE (none: a commit-only job).
/// In order: an instance already at INPUTS (the same tree shares it); the one WORKTREE last leased (its build dir is
/// warm); a new instance while the family has fewer than LIMIT; the least recently used one no job reads. MOVE_TO
/// moves an instance to INPUTS under its update lock ([`hold`]). `None` when every instance is read at other inputs
/// and the family is at its limit: the job waits and holds nothing (no folder is made for it).
pub fn lease(
    root: &Path,
    key: &SlotFamily,
    inputs: &str,
    worktree: Option<&Path>,
    limit: u32,
    mut move_to: impl FnMut(&SlotPaths) -> Result<()>,
) -> Result<Option<Lease>> {
    let all = instances(root, key);
    let take =
        |n: u32, move_to: &mut dyn FnMut(&SlotPaths) -> Result<()>| -> Result<Option<Lease>> {
            let paths = paths(root, key, n);
            let Some(held) = hold(&paths, inputs, || move_to(&paths))? else {
                return Ok(None);
            };
            if let Some(w) = worktree {
                crate::fsio::write(paths.git_dir.join(WORKTREE), w.as_os_str().as_bytes())?;
            }
            Ok(Some(Lease { n, paths, held }))
        };
    // the same inputs share an instance
    for i in &all {
        if holds(&paths(root, key, i.n).git_dir, inputs)
            && let Some(l) = take(i.n, &mut move_to)?
        {
            return Ok(Some(l));
        }
    }
    // the instances no job reads (an update lock is free); a race is settled by `hold` again
    let free: Vec<SlotInstance> = all
        .iter()
        .filter(|i| {
            Locks::of(&paths(root, key, i.n))
                .try_update()
                .is_ok_and(|l| l.is_some())
        })
        .cloned()
        .collect();
    let under_limit = (all.len() as u32) < limit;
    let own = worktree.is_some_and(|w| free.iter().any(|f| f.worktree.as_deref() == Some(w)));
    let pick = if own || !under_limit || worktree.is_none() {
        pick_instance(&free, worktree).map(|i| free[i].n)
    } else {
        None
    };
    let n = match pick {
        Some(n) => n,
        None if under_limit => (0..).find(|n| !all.iter().any(|i| i.n == *n)).unwrap_or(0),
        None => return Ok(None),
    };
    take(n, &mut move_to)
}

/// The job to wait for when INPUTS can't be leased: among HOLDERS (the running jobs that read the family's slots, each
/// its job id and inputs), none when INPUTS is among their inputs or fewer than LIMIT distinct inputs are held;
/// else the job holding the first of them.
pub fn wait_for<'a>(holders: &[(&'a str, &str)], inputs: &str, limit: u32) -> Option<&'a str> {
    if holders.iter().any(|(_, i)| *i == inputs) {
        return None;
    }
    let mut distinct: Vec<&str> = holders.iter().map(|(_, i)| *i).collect();
    distinct.sort_unstable();
    distinct.dedup();
    if (distinct.len() as u32) < limit {
        return None;
    }
    holders.first().map(|(j, _)| *j)
}

/// Every attribute that changes bytes between git and the checkout, unset for every path: the slot holds exactly
/// the bytes captured. `info/attributes` outranks every `.gitattributes` in the tree.
const ATTRIBUTES: &str = "* -text -ident -filter -working-tree-encoding\n";

/// Moves the slot to `commit` (which the bare `mirror` holds) plus `overlay`. Every path and the commit id are
/// checked before anything changes. The caller holds the update lock ([`hold`] does).
pub fn update(p: &SlotPaths, mirror: &Path, commit: &str, overlay: &Overlay) -> Result<()> {
    let oid_ok = matches!(commit.len(), 40 | 64)
        && commit
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if !oid_ok {
        return Err(refused(commit.as_bytes(), "not an object id"));
    }
    let entries: Vec<&Entry> = overlay.entries.iter().chain(overlay.extras).collect();
    for e in &entries {
        check_path(e.path()).map_err(|why| refused(e.path(), why))?;
        if let Entry::File { mode, .. } = e
            && ![MODE_FILE, MODE_EXEC, MODE_LINK].contains(mode)
        {
            return Err(refused(e.path(), "a mode git doesn't store"));
        }
    }

    let git = Git {
        git_dir: p.git_dir.clone(),
        work_tree: Some(p.slot.clone()),
    };
    if fs::symlink_metadata(p.git_dir.join("HEAD")).is_err() {
        // a slot without its git dir is a stray: start it again from nothing
        match fs::remove_dir_all(&p.slot) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e.into()),
            _ => {}
        }
        fs::create_dir_all(&p.git_dir)?;
        fs::create_dir_all(&p.slot)?;
        run(
            "make the slot's git dir",
            git.cmd(["init", "-q", "--template="]),
            None,
        )?;
    }
    fs::create_dir_all(&p.slot)?;
    remove_dot_git(&p.slot)?;
    fs::create_dir_all(p.git_dir.join("objects/info"))?;
    let mut alternates = mirror.join("objects").into_os_string().into_vec();
    alternates.push(b'\n');
    crate::fsio::write(p.git_dir.join("objects/info/alternates"), alternates)?;
    fs::create_dir_all(p.git_dir.join("info"))?;
    crate::fsio::write(p.git_dir.join("info/attributes"), ATTRIBUTES)?;
    touch(&p.git_dir.join("used"))?;

    // the wanted index: the commit, then the overlay's deletions and files, in a temporary index
    let next = p.git_dir.join("sleipnir-next.index");
    remove_if_there(&next)?;
    let with_next = |args: &[&str]| {
        let mut c = git.cmd(args);
        super::git::set_env(&mut c, "GIT_INDEX_FILE", &next);
        c
    };
    run("read the commit", with_next(&["read-tree", commit]), None)?;
    let files: Vec<(&[u8], u32, PathBuf)> = entries
        .iter()
        .filter_map(|e| match e {
            Entry::File {
                path, mode, sha256, ..
            } => Some((&path[..], *mode, overlay.blobs.path(sha256))),
            Entry::Deleted { .. } => None,
        })
        .collect();
    let mut oids = Vec::new();
    if !files.is_empty() {
        let mut list = Vec::new();
        for (_, _, blob) in &files {
            let b = blob.as_os_str().as_bytes();
            if b.contains(&b'\n') {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "a blob path with a newline",
                )
                .into());
            }
            list.extend_from_slice(b);
            list.push(b'\n');
        }
        let out = run(
            "store the overlay",
            git.cmd(["hash-object", "-w", "--no-filters", "--stdin-paths"]),
            Some(&list),
        )?;
        oids = out
            .split(|&b| b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| l.to_vec())
            .collect();
        if oids.len() != files.len() {
            return Err(SyncError::Git {
                what: "store the overlay",
                code: None,
                stderr: "unexpected output".into(),
            });
        }
    }
    let zero = "0".repeat(commit.len());
    let mut info = Vec::new();
    for e in &entries {
        if let Entry::Deleted { path } = e {
            info.extend_from_slice(format!("0 {zero}\t").as_bytes());
            info.extend_from_slice(path);
            info.push(0);
        }
    }
    for ((path, mode, _), oid) in files.iter().zip(&oids) {
        info.extend_from_slice(format!("{mode:o} ").as_bytes());
        info.extend_from_slice(oid);
        info.push(b'\t');
        info.extend_from_slice(path);
        info.push(0);
    }
    run(
        "add the overlay",
        with_next(&["update-index", "-z", "--index-info"]),
        Some(&info),
    )?;
    let tree = line(&run(
        "write the wanted tree",
        with_next(&["write-tree"]),
        None,
    )?);
    remove_if_there(&next)?;

    // stat changes alone (a touch, a relabel) are not changes: refresh them, so only content is rewritten
    let refresh = spawn(git.cmd(["update-index", "-q", "--refresh"]), None)?;
    if !matches!(refresh.code, Some(0 | 1)) {
        return Err(refresh.failed("refresh the slot's index"));
    }
    run(
        "update the checkout",
        git.cmd(["read-tree", "--reset", "-u", &tree]),
        None,
    )?;
    run(
        "detach HEAD at the commit",
        git.cmd(["update-ref", "--no-deref", "HEAD", commit]),
        None,
    )?;
    Ok(())
}

/// Deletes every `.git` (a directory, a file or a link, in any case) under `dir`, never following a link.
fn remove_dot_git(dir: &Path) -> io::Result<()> {
    for e in fs::read_dir(dir)? {
        let e = e?;
        let ft = e.file_type()?;
        if e.file_name().as_bytes().eq_ignore_ascii_case(b".git") {
            if ft.is_dir() {
                fs::remove_dir_all(e.path())?;
            } else {
                fs::remove_file(e.path())?;
            }
        } else if ft.is_dir() {
            remove_dot_git(&e.path())?;
        }
    }
    Ok(())
}

/// A private copy of the slot at `dest` (which must not exist) for a job that writes the tree. Files keep their
/// mode and mtime (the slot's target dir stays warm for the copy); links are copied as links, never followed.
pub fn private_copy(p: &SlotPaths, dest: &Path) -> Result<CopyKind> {
    fs::create_dir(dest)?;
    let mut plain = false;
    copy_tree(&p.slot, dest, &mut plain)?;
    Ok(if plain {
        CopyKind::Plain
    } else {
        CopyKind::Reflink
    })
}

fn copy_tree(src: &Path, dst: &Path, plain: &mut bool) -> Result<()> {
    for e in fs::read_dir(src)? {
        let e = e?;
        let ft = e.file_type()?;
        let (from, to) = (e.path(), dst.join(e.file_name()));
        if ft.is_dir() {
            fs::create_dir(&to)?;
            copy_tree(&from, &to, plain)?;
        } else if ft.is_symlink() {
            symlink(fs::read_link(&from)?, &to)?;
        } else if ft.is_file() {
            let mut r = fs::File::open(&from)?;
            let meta = r.metadata()?;
            // a Mac clones by name (APFS `fclonefileat` makes the file), elsewhere into an open file (FICLONE)
            let w = if clone_new(&r, &to) {
                crate::fsio::open_existing(&to)?
            } else {
                let mut w = crate::fsio::create_new(&to, 0o600)?;
                if !clone(&w, &r) {
                    *plain = true;
                    io::copy(&mut r, &mut w)?;
                }
                w
            };
            w.set_permissions(meta.permissions())?;
            w.set_times(
                fs::FileTimes::new()
                    .set_accessed(meta.accessed()?)
                    .set_modified(meta.modified()?),
            )?;
        } else {
            return Err(refused(
                from.as_os_str().as_bytes(),
                "neither a file, a directory nor a link",
            ));
        }
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn clone(to: &fs::File, from: &fs::File) -> bool {
    rustix::fs::ioctl_ficlone(to, from).is_ok()
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn clone(_: &fs::File, _: &fs::File) -> bool {
    false
}

/// Makes TO a clone of FROM (APFS): false where the file system can't, and TO isn't made.
#[cfg(target_os = "macos")]
fn clone_new(from: &fs::File, to: &Path) -> bool {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn fclonefileat(
            srcfd: libc::c_int,
            dst_dirfd: libc::c_int,
            dst: *const libc::c_char,
            flags: u32,
        ) -> libc::c_int;
    }
    let Ok(name) = std::ffi::CString::new(to.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: an open file, the current directory and a NUL-terminated path; no flags
    unsafe { fclonefileat(from.as_raw_fd(), libc::AT_FDCWD, name.as_ptr(), 0) == 0 }
}

#[cfg(not(target_os = "macos"))]
fn clone_new(_: &fs::File, _: &Path) -> bool {
    false
}

/// The slot's locks: `flock`s on files in its git dir, so they hold across processes and go with a process that dies.
/// A job that reads the slot is held by read locks for its life ([`hold`]: `serve` from the checkout, the job's
/// job-exec from its start, [`hold_for_job`]), so no `serve` of any hub moves the slot under it, and `gc` and the disk
/// guard keep it.
pub struct Locks {
    git_dir: PathBuf,
}

/// A held lock, released when dropped.
pub struct Held {
    _file: fs::File,
}

impl Locks {
    pub fn of(p: &SlotPaths) -> Locks {
        Locks {
            git_dir: p.git_dir.clone(),
        }
    }

    /// Shared with other readers; waits for an update. Marks the slot used.
    pub fn read(&self) -> Result<Held> {
        let held = self
            .lock("slot.lock", FlockOperation::LockShared)?
            .expect("a blocking lock");
        touch(&self.git_dir.join("used"))?;
        Ok(held)
    }

    /// Exclusive, or `None` at once while a reader or another update holds the slot.
    pub fn try_update(&self) -> Result<Option<Held>> {
        self.lock("slot.lock", FlockOperation::NonBlockingLockExclusive)
    }

    /// Exclusive on the slot's target dir, for a job that builds into it.
    pub fn target(&self) -> Result<Held> {
        Ok(self
            .lock("target.lock", FlockOperation::LockExclusive)?
            .expect("a blocking lock"))
    }

    /// `target`, or `None` at once while another job holds it.
    pub fn try_target(&self) -> Result<Option<Held>> {
        self.lock("target.lock", FlockOperation::NonBlockingLockExclusive)
    }

    fn lock(&self, name: &str, op: FlockOperation) -> Result<Option<Held>> {
        fs::create_dir_all(&self.git_dir)?;
        let file = crate::fsio::open_lock(self.git_dir.join(name), 0o666)?;
        match rustix::fs::flock(&file, op) {
            Ok(()) => Ok(Some(Held { _file: file })),
            Err(rustix::io::Errno::WOULDBLOCK) => Ok(None),
            Err(e) => Err(io::Error::from(e).into()),
        }
    }
}

/// The record of the inputs a slot holds (the hub's input key), in its git dir: written under the update lock once a
/// move is done, removed before one starts.
const INPUTS: &str = "inputs";

/// Whether the slot whose git dir is GIT_DIR holds INPUTS (an empty key is never held).
fn holds(git_dir: &Path, inputs: &str) -> bool {
    !inputs.is_empty()
        && crate::fsio::read_to_string(git_dir.join(INPUTS)).is_ok_and(|s| s == inputs)
}

/// A read lock on slot P once it holds INPUTS, for a job that reads it: the slot is moved there first by MOVE (under
/// the update lock) when no job reads it at other inputs; `None` while one does. The check and the read lock are one
/// step, so between this answer and the job's end no process moves the slot: a move needs the update lock, which
/// waits for no reader.
pub fn hold(
    p: &SlotPaths,
    inputs: &str,
    mut move_to: impl FnMut() -> Result<()>,
) -> Result<Option<Held>> {
    let locks = Locks::of(p);
    let mut readers = false;
    // a lock can't be turned from exclusive to shared in one step, so after a move the slot is read again; three
    // rounds only end without an answer when other processes keep moving it in between
    for _ in 0..3 {
        let held = locks.read()?;
        if holds(&p.git_dir, inputs) {
            return Ok(Some(held));
        }
        drop(held);
        if readers {
            return Ok(None);
        }
        match locks.try_update()? {
            // a job reads it: at other inputs, unless it was moved to ours meanwhile (the next round sees)
            None => readers = true,
            Some(_update) => {
                if !holds(&p.git_dir, inputs) {
                    remove_if_there(&p.git_dir.join(INPUTS))?;
                    move_to()?;
                    crate::fsio::write(p.git_dir.join(INPUTS), inputs)?;
                }
            }
        }
    }
    Ok(None)
}

/// The file in an attempt's folder that names the slot its job reads: its input key, a newline, the slot's git dir.
pub const JOB_HOLD: &str = "slot-hold";

/// Writes DIR's [`JOB_HOLD`]: its job reads slot P at INPUTS.
pub fn write_job_hold(dir: &Path, p: &SlotPaths, inputs: &str) -> io::Result<()> {
    let mut body = format!("{inputs}\n").into_bytes();
    body.extend_from_slice(p.git_dir.as_os_str().as_bytes());
    crate::fsio::write(dir.join(JOB_HOLD), body)
}

/// The read lock job-exec holds for its job's life, on the slot DIR's [`JOB_HOLD`] names (none named: `Ok(None)`). An
/// error when the slot no longer holds the job's inputs (moved between `serve`'s checkout and this start: that `serve`
/// is gone) or can't be locked: the job must not run.
pub fn hold_for_job(dir: &Path) -> villa::Result<Option<Held>> {
    let body = match fs::read(dir.join(JOB_HOLD)) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(villa::Error::io(format!("{JOB_HOLD}: {e}")).with_source(e)),
        Ok(b) => b,
    };
    let at = body
        .iter()
        .position(|&b| b == b'\n')
        .ok_or_else(|| villa::Error::invalid(format!("{JOB_HOLD}: no slot named")))?;
    let inputs = std::str::from_utf8(&body[..at])
        .map_err(|_| villa::Error::invalid(format!("{JOB_HOLD}: not a key")))?;
    let git_dir = Path::new(std::ffi::OsStr::from_bytes(&body[at + 1..]));
    let held = Locks {
        git_dir: git_dir.to_path_buf(),
    }
    .read()
    .map_err(|e| villa::Error::conflict(format!("the checkout slot's read lock: {e}")))?;
    if !holds(git_dir, inputs) {
        return Err(villa::Error::conflict(
            "its checkout slot moved to other inputs before the job started",
        ));
    }
    Ok(Some(held))
}

/// Instance N of slot family KEY (its directories P, under REG's runner folder) and its build dir in the disk
/// register, used at NOW: on lease and on every use, so the guard ages them from their last job
/// (`slot:<id>-<n>`, `build:<id>-<n>`).
pub fn register(
    reg: &mut Register,
    p: &SlotPaths,
    key: &SlotFamily,
    n: u32,
    now: u64,
) -> villa::Result<()> {
    let id = key.instance_id(n);
    for (kind, item_id, dir) in [
        (ItemKind::Slot, format!("slot:{id}"), &p.slot),
        (ItemKind::BuildDir, format!("build:{id}"), &p.target),
    ] {
        let rel = dir
            .strip_prefix(reg.root())
            .map_err(|_| villa::Error::refused("a slot outside the runner folder"))?
            .to_path_buf();
        reg.add(
            DiskItem {
                id: item_id,
                kind,
                owner: key.project.clone(),
                machine: String::new(),
                bytes: 0,
                last_used: now,
                created: now,
                name: None,
                budget_bytes: None,
                trust: key.trust,
            },
            &rel,
        )?;
    }
    Ok(())
}

/// A read-only git dir for a job whose pack says `git = "ro"`, made at DEST (which must not exist), outside the slot:
/// `HEAD` at COMMIT, a copy of the slot P's index, the mirror's objects through `objects/info/alternates` and its tags,
/// and no file writable (its folders stay removable, so the attempt's cleanup needs no chmod). The job gets it as `GIT_DIR` (with `GIT_WORK_TREE` the slot), mounted
/// read-only, so `git describe` and `git status` work and nothing a job does can change history. Through the alternates
/// it can read every object of its project's mirror at its trust.
pub fn git_ro(dest: &Path, p: &SlotPaths, mirror_git: &Path, commit: &str) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let oid_ok = matches!(commit.len(), 40 | 64)
        && commit
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if !oid_ok {
        return Err(refused(commit.as_bytes(), "not an object id"));
    }
    // never over an existing folder
    fs::create_dir(dest)?;
    fs::create_dir_all(dest.join("objects/info"))?;
    fs::create_dir_all(dest.join("refs/tags"))?;
    fs::create_dir_all(dest.join("info"))?;
    let mut files: Vec<(PathBuf, Vec<u8>)> = vec![
        (dest.join("HEAD"), format!("{commit}\n").into_bytes()),
        (dest.join("index"), fs::read(p.git_dir.join("index"))?),
        (
            dest.join("config"),
            fs::read(p.git_dir.join("config")).unwrap_or_default(),
        ),
        (dest.join("info/attributes"), ATTRIBUTES.as_bytes().to_vec()),
    ];
    let mut alternates = mirror_git.join("objects").into_os_string().into_vec();
    alternates.push(b'\n');
    files.push((dest.join("objects/info/alternates"), alternates));
    if let Ok(packed) = fs::read(mirror_git.join("packed-refs")) {
        files.push((dest.join("packed-refs"), packed));
    }
    // the mirror's loose tags
    if let Ok(rd) = fs::read_dir(mirror_git.join("refs/tags")) {
        for e in rd
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        {
            files.push((
                dest.join("refs/tags").join(e.file_name()),
                fs::read(e.path())?,
            ));
        }
    }
    for (path, body) in files {
        crate::fsio::write(&path, body)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o444))?;
    }
    Ok(())
}

fn touch(path: &Path) -> io::Result<()> {
    let f = crate::fsio::open_lock(path, 0o666)?;
    f.set_modified(stund::wall())
}

fn remove_if_there(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::time::{Duration, SystemTime};

    use super::super::SyncError;
    use super::super::capture::{self, MODE_FILE};
    use super::super::testutil::{self, DirBlobs, HOOKS, marker_script, user_git, write};
    use super::*;

    fn key(project: &str) -> SlotFamily {
        SlotFamily {
            project: project.into(),
            trust: JobTrust::Private,
            toolchain: "t".into(),
            cone: String::new(),
            role: forseti::Role::Author,
        }
    }

    /// Captures `repo` and updates the slot `p` to it.
    fn sync(t: &Path, repo: &Path, p: &SlotPaths) {
        let i = capture::capture(repo, &[]).unwrap();
        let blobs = DirBlobs::of(&t.join("blobs"), repo, &i);
        update(p, &repo.join(".git"), &i.commit, &Overlay::of(&i, &blobs)).unwrap();
    }

    fn mtime(p: &Path) -> SystemTime {
        fs::symlink_metadata(p).unwrap().modified().unwrap()
    }

    fn backdate(p: &Path, to: SystemTime) {
        crate::fsio::open_existing(p)
            .unwrap()
            .set_modified(to)
            .unwrap();
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn only_changed_files_get_a_new_mtime() {
        let t = tempfile::tempdir().unwrap();
        let files: [(&[u8], &[u8]); 4] = [
            (b"a", b"a\n"),
            (b"b", b"b\n"),
            (b"c", b"c\n"),
            (b"d", b"d\n"),
        ];
        let (repo, _) = testutil::repo(t.path(), &files);
        write(&repo, b"b", b"b in the overlay\n");
        write(&repo, b"x", b"untracked\n");
        let p = paths(&t.path().join("runner"), &key("w"), 0);
        sync(t.path(), &repo, &p);

        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        for f in ["a", "b", "c", "d", "x"] {
            backdate(&p.slot.join(f), old);
        }
        // a new commit changes c; the overlay keeps b and x, adds y and deletes a
        write(&repo, b"c", b"c committed again\n");
        user_git(&repo, &["commit", "-qm", "two", "c"]);
        write(&repo, b"y", b"new in the overlay\n");
        fs::remove_file(repo.join("a")).unwrap();
        sync(t.path(), &repo, &p);

        for f in ["b", "d", "x"] {
            assert_eq!(
                mtime(&p.slot.join(f)),
                old,
                "{f} is unchanged and keeps its mtime"
            );
        }
        for f in ["c", "y"] {
            assert!(
                mtime(&p.slot.join(f)) > old + Duration::from_secs(3600),
                "{f} changed and has a new mtime"
            );
        }
        assert!(!p.slot.join("a").exists(), "a deletion is removed");
        assert_eq!(fs::read(p.slot.join("b")).unwrap(), b"b in the overlay\n");
        assert_eq!(fs::read(p.slot.join("c")).unwrap(), b"c committed again\n");
    }

    // [D] a Mac's private copy is an APFS clone (the CI host's volume): every file shares its blocks
    #[cfg(target_os = "macos")]
    #[test]
    fn darwin_private_copies_are_clones() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        let p = paths(&t.path().join("runner"), &key("w"), 0);
        sync(t.path(), &repo, &p);
        let dest = t.path().join("job/tree");
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        assert!(matches!(
            private_copy(&p, &dest).unwrap(),
            CopyKind::Reflink
        ));
        assert_eq!(testutil::tree(&dest), testutil::tree(&p.slot));
    }

    // [D] pure (a temp repo, real git)
    #[test]
    fn writes_tree_gets_a_private_copy() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) =
            testutil::repo(t.path(), &[(b"a", b"a\n"), (b"sub/run.sh", b"#!/bin/sh\n")]);
        fs::set_permissions(repo.join("sub/run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        symlink("a", repo.join("ln")).unwrap();
        testutil::commit_all(&repo, "two");
        write(&repo, b"overlay", b"o\n");
        let p = paths(&t.path().join("runner"), &key("w"), 0);
        sync(t.path(), &repo, &p);

        let dest = t.path().join("job/tree");
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        let kind = private_copy(&p, &dest).unwrap();
        assert!(matches!(kind, CopyKind::Reflink | CopyKind::Plain));
        assert_eq!(testutil::tree(&dest), testutil::tree(&p.slot));
        for f in ["a", "sub/run.sh", "overlay"] {
            assert_eq!(
                mtime(&dest.join(f)),
                mtime(&p.slot.join(f)),
                "{f} keeps its mtime, so builds stay warm"
            );
        }
        assert_eq!(
            fs::metadata(dest.join("sub/run.sh"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        assert!(
            fs::symlink_metadata(dest.join("ln"))
                .unwrap()
                .file_type()
                .is_symlink()
        );

        crate::fsio::write(dest.join("a"), b"the job wrote this\n").unwrap();
        assert_eq!(
            fs::read(p.slot.join("a")).unwrap(),
            b"a\n",
            "a write into the copy never reaches the slot"
        );
        assert!(
            private_copy(&p, &dest).is_err(),
            "never a copy into an existing tree"
        );
    }

    /// Syncs a repo once, lets `plant` write into the slot what a job could, then syncs a new commit and overlay.
    /// Returns the slot's paths and the marker every planted program would append to.
    fn plant_then_sync(t: &Path, plant: impl FnOnce(&SlotPaths, &Path)) -> SlotPaths {
        let (repo, _) = testutil::repo(t, &[(b"a", b"a\n"), (b"dir/file", b"f\n")]);
        let p = paths(&t.join("runner"), &key("w"), 0);
        sync(t, &repo, &p);
        let marker = t.join("marker");
        plant(&p, &marker);
        write(&repo, b"a", b"a two\n");
        write(&repo, b"c", b"c\n");
        testutil::commit_all(&repo, "two");
        write(&repo, b"dir/file", b"f in the overlay\n");
        write(&repo, b"dir/new", b"new\n");
        sync(t, &repo, &p);
        assert!(
            !marker.exists(),
            "a planted program ran: {:?}",
            crate::fsio::read_to_string(&marker)
        );
        assert!(
            fs::symlink_metadata(p.slot.join(".git")).is_err(),
            "the planted .git is gone"
        );
        assert_eq!(fs::read(p.slot.join("a")).unwrap(), b"a two\n");
        assert_eq!(fs::read(p.slot.join("c")).unwrap(), b"c\n");
        assert_eq!(
            fs::read(p.slot.join("dir/file")).unwrap(),
            b"f in the overlay\n"
        );
        assert_eq!(fs::read(p.slot.join("dir/new")).unwrap(), b"new\n");
        p
    }

    /// A real repository at `slot/.git`, as a job would make one, so a git that looked there would use it.
    fn plant_repo(slot: &Path) -> PathBuf {
        user_git(slot, &["init", "-q"]);
        slot.join(".git")
    }

    // [D] pure: sync never runs a hook a job planted in its slot
    #[test]
    fn a_planted_post_checkout_hook_never_runs() {
        let t = tempfile::tempdir().unwrap();
        plant_then_sync(t.path(), |p, marker| {
            let git = plant_repo(&p.slot);
            for h in HOOKS {
                marker_script(&git.join("hooks").join(h), marker, h);
            }
        });
    }

    // [D] pure: sync never runs a core.fsmonitor from a config a job planted in its slot
    #[test]
    fn core_fsmonitor_in_a_planted_config_never_runs() {
        let t = tempfile::tempdir().unwrap();
        plant_then_sync(t.path(), |p, marker| {
            plant_repo(&p.slot);
            let monitor = p.slot.join("monitor.sh");
            marker_script(&monitor, marker, "fsmonitor");
            user_git(
                &p.slot,
                &["config", "core.fsmonitor", monitor.to_str().unwrap()],
            );
        });
    }

    // [D] pure: sync never runs the hooks a job wrote and pointed a planted config's core.hooksPath at
    #[test]
    fn a_planted_core_hookspath_never_runs() {
        let t = tempfile::tempdir().unwrap();
        plant_then_sync(t.path(), |p, marker| {
            plant_repo(&p.slot);
            let hooks = p.slot.join("evil-hooks");
            for h in HOOKS {
                marker_script(&hooks.join(h), marker, h);
            }
            user_git(
                &p.slot,
                &["config", "core.hooksPath", hooks.to_str().unwrap()],
            );
        });
    }

    // [D] pure: sync never follows a `.git` file (or a `.git` link) naming a git dir the job made outside the slot
    #[test]
    fn a_dot_git_file_in_the_slot_is_deleted_not_followed() {
        let t = tempfile::tempdir().unwrap();
        let evil = t.path().join("evil");
        fs::create_dir(&evil).unwrap();
        user_git(&evil, &["init", "-q"]);
        let evil_git = evil.join(".git");
        let mut before = None;
        let p = plant_then_sync(t.path(), |p, marker| {
            for h in HOOKS {
                marker_script(&evil_git.join("hooks").join(h), marker, h);
            }
            let monitor = evil.join("monitor.sh");
            marker_script(&monitor, marker, "fsmonitor");
            user_git(
                &evil,
                &["config", "core.fsmonitor", monitor.to_str().unwrap()],
            );
            crate::fsio::write(
                p.slot.join(".git"),
                format!("gitdir: {}\n", evil_git.display()),
            )
            .unwrap();
            fs::create_dir(p.slot.join("sub")).unwrap();
            symlink(&evil_git, p.slot.join("sub/.git")).unwrap();
            before = Some(testutil::tree(&evil));
        });
        assert!(
            fs::symlink_metadata(p.slot.join("sub/.git")).is_err(),
            "a .git link is removed"
        );
        assert_eq!(
            Some(testutil::tree(&evil)),
            before,
            "the named git dir is never followed or written"
        );
    }

    // [D] pure: links a job planted never lead sync's writes out of the slot
    #[test]
    fn a_planted_link_never_leads_a_write_outside() {
        let t = tempfile::tempdir().unwrap();
        let outside = t.path().join("outside");
        fs::create_dir(&outside).unwrap();
        let sentinel = t.path().join("sentinel");
        crate::fsio::write(&sentinel, b"keep\n").unwrap();
        let p = plant_then_sync(t.path(), |p, _| {
            fs::remove_dir_all(p.slot.join("dir")).unwrap();
            symlink(&outside, p.slot.join("dir")).unwrap();
            fs::remove_file(p.slot.join("a")).unwrap();
            symlink(&sentinel, p.slot.join("a")).unwrap();
        });
        assert_eq!(
            fs::read_dir(&outside).unwrap().count(),
            0,
            "nothing was written through the planted dir link"
        );
        assert_eq!(
            fs::read(&sentinel).unwrap(),
            b"keep\n",
            "nothing was written through the planted file link"
        );
        assert!(fs::symlink_metadata(p.slot.join("dir")).unwrap().is_dir());
        assert!(fs::symlink_metadata(p.slot.join("a")).unwrap().is_file());
    }

    // [D] pure: paths and ids an update never takes, refused before anything changes
    #[test]
    fn update_refuses_what_it_never_writes() {
        let t = tempfile::tempdir().unwrap();
        let (repo, commit) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        let p = paths(&t.path().join("runner"), &key("w"), 0);
        sync(t.path(), &repo, &p);
        let before = testutil::tree(&p.slot);
        let blobs = DirBlobs {
            dir: t.path().join("blobs"),
        };
        let file = |path: &[u8], mode| Entry::File {
            path: path.to_vec(),
            mode,
            sha256: [0; 32],
            size: 0,
        };
        for (entry, why) in [
            (
                file(b".git/hooks/post-checkout", MODE_FILE),
                "a .git component",
            ),
            (file(b"sub/.Git/config", MODE_FILE), "a .git component"),
            (file(b"../escape", MODE_FILE), "a . or .. component"),
            (file(b"/etc/passwd", MODE_FILE), "an absolute path"),
            (file(b"setuid", 0o104755), "a mode git doesn't store"),
            (
                Entry::Deleted {
                    path: b"dir/".to_vec(),
                },
                "an empty component",
            ),
        ] {
            let entries = [entry];
            let o = Overlay {
                entries: &entries,
                extras: &[],
                blobs: &blobs,
            };
            match update(&p, &repo.join(".git"), &commit, &o) {
                Err(SyncError::Refused { why: w, .. }) => assert_eq!(w, why),
                other => panic!("{:?}: expected Refused, got {other:?}", entries[0]),
            }
        }
        let none = Overlay {
            entries: &[],
            extras: &[],
            blobs: &blobs,
        };
        for bad in ["--upload-pack=touch", "HEAD", "", &commit[..39]] {
            assert!(
                matches!(
                    update(&p, &repo.join(".git"), bad, &none),
                    Err(SyncError::Refused { .. })
                ),
                "{bad}"
            );
        }
        assert_eq!(testutil::tree(&p.slot), before);
    }

    // [D] pure (the guard's removal of slots: sync::guard's tests)
    #[test]
    fn a_slot_registers_on_lease_and_touches_on_use() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        let k = key("w");
        let p = paths(&root, &k, 1);
        let mut reg = Register::open(&root).unwrap();
        register(&mut reg, &p, &k, 1, 100).unwrap();
        register(&mut reg, &p, &k, 1, 500).unwrap();
        let id = k.instance_id(1);
        let (slot, rel) = reg.get(&format!("slot:{id}")).unwrap();
        assert_eq!(
            (slot.kind, slot.created, slot.last_used, slot.trust),
            (ItemKind::Slot, 100, 500, JobTrust::Private)
        );
        assert_eq!(rel, Path::new("slots").join(&id));
        let (build, rel) = reg.get(&format!("build:{id}")).unwrap();
        assert_eq!((build.kind, build.last_used), (ItemKind::BuildDir, 500));
        assert_eq!(rel, Path::new("slots-target").join(&id));
        // a slot whose paths are not under the register's folder is refused
        let elsewhere = paths(&t.path().join("other"), &k, 1);
        assert!(register(&mut reg, &elsewhere, &k, 1, 600).is_err());
    }

    // [D] pure
    #[test]
    fn slot_keys_name_their_own_directories() {
        let root = Path::new("/r");
        let a = paths(root, &key("w"), 0);
        assert_eq!(a, paths(root, &key("w"), 0));
        let other = SlotFamily {
            trust: JobTrust::PrivateKeys,
            ..key("w")
        };
        assert_ne!(
            a.slot,
            paths(root, &other, 0).slot,
            "trust levels never share a slot"
        );
        assert_ne!(
            a.target,
            paths(root, &key("w2"), 0).target,
            "projects never share a target dir"
        );
        assert_ne!(
            a.target,
            paths(root, &key("w"), 1).target,
            "instances differ"
        );
        assert_eq!(a.slot.parent().unwrap(), root.join("slots"));
        assert_eq!(a.git_dir.parent().unwrap(), root.join("slots-git"));
        assert_eq!(a.target.parent().unwrap(), root.join("slots-target"));
        assert_eq!(
            a.slot.file_name().unwrap().to_str().unwrap(),
            key("w").instance_id(0)
        );
    }

    // [D] pure (a folder): the slot families present are the folders under `slots/`, by family id, once each; a
    // stray file or a folder that is no instance is none, and a root with no slots has none
    #[test]
    fn present_lists_the_slot_folders() {
        let d = tempfile::tempdir().unwrap();
        assert!(present(d.path()).is_empty());
        let (a, a1, b) = (
            paths(d.path(), &key("w"), 0),
            paths(d.path(), &key("w"), 1),
            paths(d.path(), &key("w2"), 0),
        );
        for p in [&b, &a1, &a] {
            fs::create_dir_all(&p.slot).unwrap();
        }
        fs::create_dir_all(d.path().join("slots/not-an-instance")).unwrap();
        crate::fsio::write(d.path().join("slots/stray"), b"").unwrap();
        let mut want = vec![key("w").id(), key("w2").id()];
        want.sort();
        assert_eq!(present(d.path()), want);
    }

    fn lease_at(
        root: &Path,
        k: &SlotFamily,
        inputs: &str,
        worktree: Option<&str>,
        limit: u32,
    ) -> Option<Lease> {
        lease(root, k, inputs, worktree.map(Path::new), limit, |_| Ok(())).unwrap()
    }

    /// Makes instance P's `used` mark SECS past the epoch, so the order of use is the test's, not the clock's.
    fn used_at(p: &SlotPaths, secs: u64) {
        crate::fsio::open_lock(p.git_dir.join("used"), 0o666)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs))
            .unwrap();
    }

    // [D] pure (a folder): jobs at one tree's inputs share one instance, each with its own read lock
    #[test]
    fn same_tree_shares_a_slot() {
        let t = tempfile::tempdir().unwrap();
        let k = key("w");
        let a = lease_at(t.path(), &k, "i1", Some("/wt/a"), 4).expect("a free family leases");
        let b = lease_at(t.path(), &k, "i1", Some("/wt/a"), 4).expect("the same inputs share");
        assert_eq!((a.n, b.n), (0, 0));
        assert_eq!(a.paths, b.paths);
        assert!(
            Locks::of(&a.paths).try_update().unwrap().is_none(),
            "two readers hold it"
        );
        assert_eq!(instances(t.path(), &k).len(), 1);
    }

    // [D] pure (a folder) (RF4): another tree never moves a slot under a running job: it takes another instance
    #[test]
    fn another_tree_takes_another_slot() {
        let t = tempfile::tempdir().unwrap();
        let k = key("w");
        let a = lease_at(t.path(), &k, "i1", Some("/wt/a"), 4).unwrap();
        let b = lease_at(t.path(), &k, "i2", Some("/wt/b"), 4).expect("a free number");
        assert_eq!((a.n, b.n), (0, 1));
        assert_ne!(a.paths.slot, b.paths.slot);
        assert_ne!(a.paths.target, b.paths.target, "each has its own build dir");
        assert_eq!(
            crate::fsio::read_to_string(a.paths.git_dir.join(INPUTS)).unwrap(),
            "i1",
            "the first is still at its own inputs"
        );
    }

    // [D] pure (a folder): at the limit with every instance read at other inputs a job waits, holding nothing: no
    // folder, no lock; the moment a reader is gone it takes that instance
    #[test]
    fn past_the_limit_waits_as_state_holding_nothing() {
        let t = tempfile::tempdir().unwrap();
        let k = key("w");
        let a = lease_at(t.path(), &k, "i1", Some("/wt/a"), 2).unwrap();
        let b = lease_at(t.path(), &k, "i2", Some("/wt/b"), 2).unwrap();
        assert!(lease_at(t.path(), &k, "i3", Some("/wt/c"), 2).is_none());
        assert_eq!(
            instances(t.path(), &k).len(),
            2,
            "no third instance was made"
        );
        assert_eq!(
            fs::read_dir(t.path().join("slots-git")).unwrap().count(),
            2,
            "and no folder for the waiting job"
        );
        // the job it waits for: the first holder; nothing to wait for when its inputs are held or the limit is not met
        let holders = [("j1", "i1"), ("j2", "i2"), ("j3", "i1")];
        assert_eq!(wait_for(&holders, "i3", 2), Some("j1"));
        assert_eq!(wait_for(&holders, "i2", 2), None, "its own inputs share");
        assert_eq!(wait_for(&holders, "i3", 3), None, "a free number");
        assert_eq!(wait_for(&[], "i3", 2), None);
        drop(a);
        let c = lease_at(t.path(), &k, "i3", Some("/wt/c"), 2).expect("the freed instance moves");
        assert_eq!(c.n, 0);
        drop(b);
    }

    // [D] pure (a folder): a commit-only job (no worktree) takes the instance a worktree job left warm, not a new one
    #[test]
    fn a_commit_only_job_takes_the_warm_build_dir() {
        let t = tempfile::tempdir().unwrap();
        let k = key("w");
        let warm = lease_at(t.path(), &k, "worktree-inputs", Some("/wt/a"), 4).unwrap();
        let (n, target) = (warm.n, warm.paths.target.clone());
        drop(warm);
        let commit_only = lease_at(t.path(), &k, "commit-inputs", None, 4).unwrap();
        assert_eq!(commit_only.n, n);
        assert_eq!(commit_only.paths.target, target);
        assert_eq!(instances(t.path(), &k).len(), 1);
    }

    // [D] pure (a folder): a worktree goes back to the instance it last used, its build dir warm, while another is
    // older: the one it left is not the least recently used
    #[test]
    fn a_worktree_returns_to_its_last_slot_instance() {
        let t = tempfile::tempdir().unwrap();
        let k = key("w");
        let a = lease_at(t.path(), &k, "i1", Some("/wt/a"), 4).unwrap();
        let b = lease_at(t.path(), &k, "i2", Some("/wt/b"), 4).unwrap();
        assert_eq!((a.n, b.n), (0, 1));
        let (pa, pb) = (a.paths.clone(), b.paths.clone());
        drop((a, b));
        // instance 0 is the older; /wt/b's is the more recent
        used_at(&pa, 1000);
        used_at(&pb, 2000);
        let back = lease_at(t.path(), &k, "i3", Some("/wt/b"), 4).unwrap();
        assert_eq!(back.n, 1, "not the least recently used one");
        drop(back);
        // pick_instance, alone: the worktree's own, else the least recently used (the lowest number among equals)
        let free = [
            SlotInstance {
                n: 0,
                worktree: Some("/wt/a".into()),
                last_used: 50,
            },
            SlotInstance {
                n: 1,
                worktree: Some("/wt/b".into()),
                last_used: 90,
            },
            SlotInstance {
                n: 2,
                worktree: None,
                last_used: 50,
            },
        ];
        assert_eq!(pick_instance(&free, Some(Path::new("/wt/b"))), Some(1));
        assert_eq!(pick_instance(&free, Some(Path::new("/wt/zz"))), Some(0));
        assert_eq!(pick_instance(&free, None), Some(0));
        assert_eq!(pick_instance(&[], None), None);
    }

    // [D] pure (RF2, review S4.1): an instance's number comes from the disk the runner has left
    #[test]
    fn the_slot_limit_follows_free_disk() {
        const G: u64 = 1 << 30;
        // free 40 GiB, a slot of 2 and a build dir of 8: four
        assert_eq!(slot_limit(40 * G, 2 * G, 8 * G, 16), 4);
        // little left: two, never fewer
        assert_eq!(slot_limit(5 * G, 2 * G, 8 * G, 16), 2);
        assert_eq!(slot_limit(0, 2 * G, 8 * G, 16), 2);
        // a lot: the setting
        assert_eq!(slot_limit(1 << 40, 2 * G, 8 * G, 16), 16);
        assert_eq!(slot_limit(1 << 40, 2 * G, 8 * G, 6), 6);
        // nothing measured yet: an instance counts as a GiB, never a divide by zero
        assert_eq!(slot_limit(8 * G, 0, 0, 16), 8);
        // a setting under two is the setting
        assert_eq!(slot_limit(1 << 40, 2 * G, 8 * G, 1), 1);
    }

    // [D] pure (a folder): a gate never leases an instance (or its build dir) an author's run has
    #[test]
    fn a_gate_never_leases_an_author_build_dir() {
        let t = tempfile::tempdir().unwrap();
        let author = key("w");
        let gate = SlotFamily {
            role: forseti::Role::Gate,
            ..key("w")
        };
        assert_ne!(author.id(), gate.id());
        let a = lease_at(t.path(), &author, "i1", Some("/wt/a"), 4).unwrap();
        let g = lease_at(t.path(), &gate, "i1", Some("/wt/a"), 4).unwrap();
        assert_ne!(a.paths.target, g.paths.target);
        assert_ne!(a.paths.slot, g.paths.slot);
        drop(a);
        // even with the author's instance idle, and the same inputs, the gate has its own family
        let g2 = lease_at(t.path(), &gate, "i1", Some("/wt/a"), 4).unwrap();
        assert_eq!(g2.paths.target, g.paths.target);
        assert_eq!(instances(t.path(), &author).len(), 1);
        assert_eq!(instances(t.path(), &gate).len(), 1);
    }

    /// A bare mirror of a repository with one commit tagged `v1` and one more commit on top, and the slot at the tip.
    fn mirror_and_slot(t: &Path) -> (PathBuf, SlotPaths, String) {
        let (repo, _) = testutil::repo(t, &[(b"a", b"a\n")]);
        user_git(&repo, &["tag", "-a", "-m", "one", "v1"]);
        write(&repo, b"b", b"b\n");
        testutil::commit_all(&repo, "two");
        let mirror = t.join("mirror.git");
        user_git(
            t,
            &[
                "clone",
                "-q",
                "--mirror",
                repo.to_str().unwrap(),
                mirror.to_str().unwrap(),
            ],
        );
        let p = paths(&t.join("runner"), &key("w"), 0);
        sync(t, &repo, &p);
        let tip = String::from_utf8(user_git(&repo, &["rev-parse", "HEAD"]))
            .unwrap()
            .trim()
            .to_string();
        (mirror, p, tip)
    }

    // [D] pure (real git): a `git = "ro"` job's git dir answers `git describe` from the slot's files, with the tag
    #[test]
    fn a_git_ro_job_runs_git_describe() {
        let t = tempfile::tempdir().unwrap();
        let (mirror, p, tip) = mirror_and_slot(t.path());
        let dest = t.path().join("job/git");
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        git_ro(&dest, &p, &mirror, &tip).unwrap();
        let ro = super::super::git::Git {
            git_dir: dest.clone(),
            work_tree: Some(p.slot.clone()),
        };
        let out = super::super::git::run("describe", ro.cmd(["describe"]), None).unwrap();
        assert!(
            String::from_utf8_lossy(&out).starts_with("v1-1-g"),
            "{}",
            String::from_utf8_lossy(&out)
        );
        let head = super::super::git::run("head", ro.cmd(["rev-parse", "HEAD"]), None).unwrap();
        assert_eq!(super::super::git::line(&head), tip);
        let status =
            super::super::git::run("status", ro.cmd(["status", "--porcelain"]), None).unwrap();
        assert!(
            status.is_empty(),
            "the slot is clean: {}",
            String::from_utf8_lossy(&status)
        );
        assert!(
            fs::symlink_metadata(p.slot.join(".git")).is_err(),
            "the slot keeps no .git"
        );
    }

    // [D] pure (a folder): no file in the git dir is writable (the mount is read-only too: the podman argv's row;
    // its folders stay removable, so the attempt's cleanup needs no chmod)
    #[test]
    fn a_git_ro_dir_is_read_only() {
        let t = tempfile::tempdir().unwrap();
        let (mirror, p, tip) = mirror_and_slot(t.path());
        let dest = t.path().join("job/git");
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        git_ro(&dest, &p, &mirror, &tip).unwrap();
        let mut seen = 0;
        let mut stack = vec![dest.clone()];
        while let Some(d) = stack.pop() {
            let meta = fs::symlink_metadata(&d).unwrap();
            if meta.is_dir() {
                stack.extend(fs::read_dir(&d).unwrap().map(|e| e.unwrap().path()));
            } else {
                let mode = meta.permissions().mode();
                assert_eq!(mode & 0o222, 0, "{} is writable ({mode:o})", d.display());
                seen += 1;
            }
        }
        assert!(
            seen >= 3,
            "HEAD, the index and the alternates at least: {seen}"
        );
        assert!(
            git_ro(&dest, &p, &mirror, &tip).is_err(),
            "never over an existing folder"
        );
        // the mirror's objects only by alternates: the job's dir holds none of its own
        let alt = crate::fsio::read_to_string(dest.join("objects/info/alternates")).unwrap();
        assert_eq!(alt.trim(), mirror.join("objects").display().to_string());
    }
}
