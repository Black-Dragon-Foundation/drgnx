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
use std::time::{Duration, SystemTime};

use forseti::JobTrust;
use rustix::fs::FlockOperation;
use sha2::{Digest, Sha256};

use super::capture::{Entry, Inputs, MODE_EXEC, MODE_FILE, MODE_LINK};
use super::git::{Git, line, run, spawn};
use super::{Result, SyncError, check_path, hex, refused};

/// A slot no job used for this long is pruned (design 6.3).
pub const UNUSED_FOR: Duration = Duration::from_secs(7 * 24 * 3600);

/// What a slot is shared by: jobs of one project, source worktree, trust and toolchain.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SlotKey {
    pub project: String,
    pub worktree: String,
    pub trust: JobTrust,
    pub toolchain: String,
}

/// Where one slot's three directories are.
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

impl SlotKey {
    /// The slot's directory name: 32 hex digits of sha256 over the four words (the trust as the design's word),
    /// each length-prefixed.
    pub fn id(&self) -> String {
        let mut h = Sha256::new();
        for w in [
            self.project.as_str(),
            self.worktree.as_str(),
            trust_word(self.trust),
            self.toolchain.as_str(),
        ] {
            h.update((w.len() as u64).to_le_bytes());
            h.update(w.as_bytes());
        }
        hex(&h.finalize()[..16])
    }
}

/// The job trust's word: `public`, `private` or `private+keys`.
pub(crate) fn trust_word(t: JobTrust) -> &'static str {
    match t {
        JobTrust::Public => "public",
        JobTrust::Private => "private",
        JobTrust::PrivateKeys => "private+keys",
    }
}

/// The slot's directories under the runner folder `root`.
pub fn paths(root: &Path, key: &SlotKey) -> SlotPaths {
    let id = key.id();
    SlotPaths {
        slot: root.join("slots").join(&id),
        git_dir: root.join("slots-git").join(&id),
        target: root.join("slots-target").join(&id),
    }
}

/// Every attribute that changes bytes between git and the checkout, unset for every path: the slot holds exactly
/// the bytes captured. `info/attributes` outranks every `.gitattributes` in the tree.
const ATTRIBUTES: &str = "* -text -ident -filter -working-tree-encoding\n";

/// Moves the slot to `commit` (which the bare `mirror` holds) plus `overlay`. Every path and the commit id are
/// checked before anything changes. The caller holds `Locks::update`.
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
    fs::write(p.git_dir.join("objects/info/alternates"), alternates)?;
    fs::create_dir_all(p.git_dir.join("info"))?;
    fs::write(p.git_dir.join("info/attributes"), ATTRIBUTES)?;
    touch(&p.git_dir.join("used"))?;

    // the wanted index: the commit, then the overlay's deletions and files, in a temporary index
    let next = p.git_dir.join("sleipnir-next.index");
    remove_if_there(&next)?;
    let with_next = |args: &[&str]| {
        let mut c = git.cmd(args);
        c.env("GIT_INDEX_FILE", &next);
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
            let mut w = fs::File::options().write(true).create_new(true).open(&to)?;
            if !clone(&w, &r) {
                *plain = true;
                io::copy(&mut r, &mut w)?;
            }
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

/// The slot's locks: `flock`s on files in its git dir, so they hold across processes (the job helper holds a read
/// lock for its job's life) and go with a process that dies.
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

    /// Exclusive: waits for every reader.
    pub fn update(&self) -> Result<Held> {
        Ok(self
            .lock("slot.lock", FlockOperation::LockExclusive)?
            .expect("a blocking lock"))
    }

    /// `update`, or `None` at once while a reader or another update holds the slot.
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
        let file = fs::File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.git_dir.join(name))?;
        match rustix::fs::flock(&file, op) {
            Ok(()) => Ok(Some(Held { _file: file })),
            Err(rustix::io::Errno::WOULDBLOCK) => Ok(None),
            Err(e) => Err(io::Error::from(e).into()),
        }
    }
}

/// Removes the slots under `root` unused for `UNUSED_FOR` at `now`, target dir first, except those in `in_use` (slot
/// directories) and those a lock holds. Returns the slot directories removed.
pub fn gc(root: &Path, now: SystemTime, in_use: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let mut removed = Vec::new();
    let gits = match fs::read_dir(root.join("slots-git")) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(removed),
        r => r?,
    };
    let mut ids: Vec<_> = gits.collect::<io::Result<Vec<_>>>()?;
    ids.sort_by_key(|e| e.file_name());
    for e in ids {
        if !e.file_type()?.is_dir() {
            continue;
        }
        let id = e.file_name();
        let p = SlotPaths {
            slot: root.join("slots").join(&id),
            git_dir: e.path(),
            target: root.join("slots-target").join(&id),
        };
        if in_use.contains(&p.slot) {
            continue;
        }
        let used = fs::metadata(p.git_dir.join("used"))
            .or_else(|_| fs::metadata(&p.git_dir))?
            .modified()?;
        if now.duration_since(used).unwrap_or_default() < UNUSED_FOR {
            continue;
        }
        let Some(_held) = Locks::of(&p).try_update()? else {
            continue;
        };
        for d in [&p.target, &p.slot, &p.git_dir] {
            match fs::remove_dir_all(d) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e.into()),
                _ => {}
            }
        }
        removed.push(p.slot);
    }
    Ok(removed)
}

fn touch(path: &Path) -> io::Result<()> {
    let f = fs::File::options()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    f.set_modified(SystemTime::now())
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
    use std::time::Duration;

    use super::super::SyncError;
    use super::super::capture::{self, MODE_FILE};
    use super::super::testutil::{self, DirBlobs, HOOKS, marker_script, user_git, write};
    use super::*;

    fn key(n: &str) -> SlotKey {
        SlotKey {
            project: "p".into(),
            worktree: n.into(),
            trust: JobTrust::Private,
            toolchain: "t".into(),
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
        fs::File::options()
            .write(true)
            .open(p)
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
        let p = paths(&t.path().join("runner"), &key("w"));
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
        let p = paths(&t.path().join("runner"), &key("w"));
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

        fs::write(dest.join("a"), b"the job wrote this\n").unwrap();
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
        let p = paths(&t.join("runner"), &key("w"));
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
            fs::read_to_string(&marker)
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
            fs::write(
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
        fs::write(&sentinel, b"keep\n").unwrap();
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
        let p = paths(&t.path().join("runner"), &key("w"));
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

    // [D] pure (the locks' own test is tests/slot_locks.rs, alone in its binary)
    #[test]
    fn gc_prunes_only_slots_unused_for_seven_days() {
        let t = tempfile::tempdir().unwrap();
        let (repo, _) = testutil::repo(t.path(), &[(b"a", b"a\n")]);
        let root = t.path().join("runner");
        let [old, held, busy, recent] =
            ["old", "held", "busy", "recent"].map(|n| paths(&root, &key(n)));
        for p in [&old, &held, &busy, &recent] {
            sync(t.path(), &repo, p);
            fs::create_dir_all(p.target.join("debug")).unwrap();
        }
        let now = testutil::fs_now(t.path());
        for p in [&old, &held, &busy] {
            backdate(
                &p.git_dir.join("used"),
                now - UNUSED_FOR - Duration::from_secs(60),
            );
        }
        backdate(
            &recent.git_dir.join("used"),
            now - UNUSED_FOR + Duration::from_secs(60),
        );
        let reader = Locks::of(&held).read().unwrap();
        backdate(
            &held.git_dir.join("used"),
            now - UNUSED_FOR - Duration::from_secs(60),
        );

        let removed = gc(&root, now, std::slice::from_ref(&busy.slot)).unwrap();
        drop(reader);
        assert_eq!(removed, vec![old.slot.clone()]);
        for d in [&old.slot, &old.git_dir, &old.target] {
            assert!(!d.exists(), "{} is removed", d.display());
        }
        for p in [&held, &busy, &recent] {
            assert!(p.slot.join("a").exists() && p.git_dir.exists() && p.target.exists());
        }
    }

    // [D] pure
    #[test]
    fn slot_keys_name_their_own_directories() {
        let root = Path::new("/r");
        let a = paths(root, &key("w"));
        assert_eq!(a, paths(root, &key("w")));
        let other = SlotKey {
            trust: JobTrust::PrivateKeys,
            ..key("w")
        };
        assert_ne!(
            a.slot,
            paths(root, &other).slot,
            "trust levels never share a slot"
        );
        assert_ne!(
            a.target,
            paths(root, &key("w2")).target,
            "worktrees never share a target dir"
        );
        assert_eq!(a.slot.parent().unwrap(), root.join("slots"));
        assert_eq!(a.git_dir.parent().unwrap(), root.join("slots-git"));
        assert_eq!(a.target.parent().unwrap(), root.join("slots-target"));
    }
}
