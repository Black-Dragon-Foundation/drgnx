//! Step snapshots (Task 19, Calls made 15): a shadow repository per worktree under `<state>/hub/checkpoints/<hash>.git`
//! and, in it, a tree of the worktree written with a persistent per-session index (a temporary one loses the stat
//! cache and rehashes the whole tree every step), kept as `refs/drgnx/s/<sid>/<seq>`.  Secret files are never in a
//! tree.  A checkpoint is restored into a tree ([`restore_into`]) by mode, through `eitri` (no link followed), never
//! over a protected path, a `.git` or a secret file (`history::tree::restorable`).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Names that never enter a snapshot, besides the sandbox's secret files ([`gleipnir::toolchain::SECRET_FILES`]).
pub(crate) const ALSO_SECRET: &[&str] = &["secrets.env", "*.pem", "*.key", "id_rsa", "id_ed25519"];

/// What [`prune`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pruned {
    /// Under the cap already.
    Fits,
    /// Finished sessions' refs were removed (their names) and the repositories collected; now under the cap.
    Freed(Vec<String>),
    /// Over the cap with nothing finished left to remove: snapshots stop (a running task's refs are never removed).
    Stop,
}

/// A name safe in a ref and a file name.
pub(super) fn safe(sid: &str) -> String {
    sid.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// The shadow repository of WORKTREE under ROOT (`<hash>.git`; FNV-1a of the path, stable across builds).
pub fn repo_of(root: &Path, worktree: &Path) -> PathBuf {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in worktree.to_string_lossy().bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(0x100000001b3);
    }
    root.join(format!("{h:016x}.git"))
}

fn git(
    repo: &Path,
    worktree: Option<&Path>,
    index: Option<&Path>,
    args: &[&str],
) -> Result<String, String> {
    let out = git_bytes(repo, worktree, index, args)?;
    Ok(String::from_utf8_lossy(&out).trim().to_string())
}

/// [`git`]'s output as it is: not trimmed, not decoded.
fn git_bytes(
    repo: &Path,
    worktree: Option<&Path>,
    index: Option<&Path>,
    args: &[&str],
) -> Result<Vec<u8>, String> {
    let mut c = Command::new("git");
    c.env("GIT_DIR", repo)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE");
    if let Some(w) = worktree {
        c.env("GIT_WORK_TREE", w).current_dir(w);
    } else {
        c.current_dir(repo);
    }
    if let Some(i) = index {
        c.env("GIT_INDEX_FILE", i);
    }
    let out = c.args(args).output().map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(out.stdout)
}

/// PATH's bytes in TREE of WORKTREE's shadow repository (the worktree is not looked at).
pub fn blob(root: &Path, worktree: &Path, tree: &str, path: &str) -> Result<Vec<u8>, String> {
    let repo = repo_of(root, worktree);
    git_bytes(
        &repo,
        None,
        None,
        &["cat-file", "blob", &format!("{tree}:{path}")],
    )
}

/// PATH's blob id in TREE of WORKTREE's shadow repository; none when TREE has no such file.
pub fn blob_id(root: &Path, worktree: &Path, tree: &str, path: &str) -> Option<String> {
    let repo = repo_of(root, worktree);
    git(
        &repo,
        None,
        None,
        &["rev-parse", "--verify", "-q", &format!("{tree}:{path}")],
    )
    .ok()
    .filter(|s| !s.is_empty())
}

/// The unified diff of PATH between FROM_TREE and TO_TREE of WORKTREE's shadow repository.
pub fn patch(
    root: &Path,
    worktree: &Path,
    from_tree: &str,
    to_tree: &str,
    path: &str,
) -> Result<String, String> {
    let repo = repo_of(root, worktree);
    let out = git_bytes(
        &repo,
        None,
        None,
        &[
            "diff-tree",
            "-p",
            "--no-renames",
            from_tree,
            to_tree,
            "--",
            path,
        ],
    )?;
    Ok(String::from_utf8_lossy(&out).into_owned())
}

/// The pathspecs that leave the secret files out: the fixed names, EXTRA (the secrets table's paths, relative to
/// the worktree) and the usual key files, anywhere in the tree.
pub(crate) fn excludes(extra: &[String]) -> Vec<String> {
    let mut names: BTreeSet<String> = gleipnir::toolchain::SECRET_FILES
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    names.extend(ALSO_SECRET.iter().map(|s| (*s).to_string()));
    let mut out: Vec<String> = names
        .into_iter()
        .map(|n| format!(":(exclude,glob)**/{n}"))
        .collect();
    out.extend(extra.iter().map(|p| {
        format!(
            ":(exclude,glob){}",
            p.trim_start_matches("./").trim_start_matches('/')
        )
    }));
    out
}

/// A tree of WORKTREE, kept as `refs/drgnx/s/<SID>/<SEQ>` in its shadow repository under ROOT; answers the tree id.
/// EXTRA are more paths to leave out (relative to the worktree).  Blocking: callers run it off the async threads.
pub fn take(
    root: &Path,
    worktree: &Path,
    sid: &str,
    seq: u64,
    extra: &[String],
) -> Result<String, String> {
    let (_, tree) = write_tree(root, worktree, sid, extra)?;
    put(root, worktree, sid, seq, &tree)?;
    Ok(tree)
}

/// TREE kept as SID's step SEQ (`refs/drgnx/s/<SID>/<SEQ>`) in WORKTREE's shadow repository under ROOT.
fn put(root: &Path, worktree: &Path, sid: &str, seq: u64, tree: &str) -> Result<(), String> {
    let name = format!("refs/drgnx/s/{}/{seq}", safe(sid));
    git(
        &repo_of(root, worktree),
        None,
        None,
        &["update-ref", &name, tree],
    )
    .map(drop)
}

/// The ref that holds SID's turn tree ([`turn_tree`]) until its first step is written.
fn turn_ref(sid: &str) -> String {
    format!("refs/drgnx/turn/{}", safe(sid))
}

/// A tree of WORKTREE as it is before SID's turn reaches its agent, through an index of its own (the step writer's is
/// never shared) and held by a ref until [`put_turn_tree`] keeps it as the turn's first step, so a collection in
/// between does not remove it.
pub fn turn_tree(root: &Path, worktree: &Path, sid: &str) -> Result<String, String> {
    let (repo, tree) = write_tree(root, worktree, &format!("turn-{sid}"), &[])?;
    git(&repo, None, None, &["update-ref", &turn_ref(sid), &tree])?;
    Ok(tree)
}

/// TREE (a [`turn_tree`]) kept as SID's step SEQ, and its holding ref gone.
pub fn put_turn_tree(
    root: &Path,
    worktree: &Path,
    sid: &str,
    seq: u64,
    tree: &str,
) -> Result<(), String> {
    put_held(root, worktree, sid, seq, tree, &turn_ref(sid))
}

/// The refs that hold SID's trees taken before a write ([`write_tree_before`]), each until its step is written.
fn write_refs(sid: &str) -> String {
    format!("refs/drgnx/write/{}/", safe(sid))
}

/// A tree of WORKTREE as it is before the hub serves one of SID's agent's writes: the checkpoint of the edit steps that
/// closed before it and whose rows are not written yet.  Through an index of its own, and held by a ref until
/// [`put_write_tree`] keeps it as a step's.
pub fn write_tree_before(root: &Path, worktree: &Path, sid: &str) -> Result<String, String> {
    let (repo, tree) = write_tree(root, worktree, &format!("write-{sid}"), &[])?;
    git(
        &repo,
        None,
        None,
        &["update-ref", &format!("{}{tree}", write_refs(sid)), &tree],
    )?;
    Ok(tree)
}

/// TREE (a [`write_tree_before`]) kept as SID's step SEQ, and its holding ref gone.
pub fn put_write_tree(
    root: &Path,
    worktree: &Path,
    sid: &str,
    seq: u64,
    tree: &str,
) -> Result<(), String> {
    put_held(
        root,
        worktree,
        sid,
        seq,
        tree,
        &format!("{}{tree}", write_refs(sid)),
    )
}

/// TREE kept as SID's step SEQ, and the ref HELD that held it until then gone.
fn put_held(
    root: &Path,
    worktree: &Path,
    sid: &str,
    seq: u64,
    tree: &str,
    held: &str,
) -> Result<(), String> {
    put(root, worktree, sid, seq, tree)?;
    git(
        &repo_of(root, worktree),
        None,
        None,
        &["update-ref", "-d", held],
    )
    .map(drop)
}

/// A tree of WORKTREE when the user took SID's wheel, kept as `refs/drgnx/s/<SID>/wheel` (so it goes with the
/// session's other refs); answers the tree id.  Blocking.
pub fn take_held(root: &Path, worktree: &Path, sid: &str) -> Result<String, String> {
    let (repo, tree) = write_tree(root, worktree, &format!("wheel-{sid}"), &[])?;
    let name = format!("refs/drgnx/s/{}/wheel", safe(sid));
    git(&repo, None, None, &["update-ref", &name, &tree])?;
    Ok(tree)
}

/// The unified diff of every file of WORKTREE from FROM_TREE to what it holds now (a tree written through an index of its
/// own, never the step writer's, kept nowhere).  Blocking.
pub fn diff_now(
    root: &Path,
    worktree: &Path,
    sid: &str,
    from_tree: &str,
) -> Result<String, String> {
    let (repo, tree) = write_tree(root, worktree, &format!("diff-{sid}"), &[])?;
    let out = git_bytes(
        &repo,
        None,
        None,
        &["diff-tree", "-p", "-r", "--no-renames", from_tree, &tree],
    )?;
    Ok(String::from_utf8_lossy(&out).into_owned())
}

/// The tree of WORKTREE with the persistent index of KEY, written into its shadow repository; the repository and the
/// tree id.
fn write_tree(
    root: &Path,
    worktree: &Path,
    key: &str,
    extra: &[String],
) -> Result<(PathBuf, String), String> {
    let repo = repo_of(root, worktree);
    let tree = write_tree_in(&repo, worktree, key, extra)?;
    Ok((repo, tree))
}

/// The tree of WORKTREE with the persistent index of KEY, written into the shadow repository REPO; the tree id.
fn write_tree_in(
    repo: &Path,
    worktree: &Path,
    key: &str,
    extra: &[String],
) -> Result<String, String> {
    if !repo.join("HEAD").exists() {
        std::fs::create_dir_all(repo).map_err(|e| format!("{}: {e}", repo.display()))?;
        git(repo, None, None, &["init", "--bare", "-q", "."])?;
    }
    let index = repo.join(format!("index-{}", safe(key)));
    let mut add: Vec<String> = ["add", "-A", "--ignore-errors", "--", "."]
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    add.extend(excludes(extra));
    let add: Vec<&str> = add.iter().map(String::as_str).collect();
    git(repo, Some(worktree), Some(&index), &add)?;
    git(repo, Some(worktree), Some(&index), &["write-tree"])
}

/// The tree of WORKTREE as it is when it is made, kept as `refs/drgnx/base/<hash>` in its shadow repository: the base
/// the interim diffs measure from (an agent's own tree never runs git for it). KEY names the index it is written
/// through (its branch or session). None when it cannot be taken.
pub fn take_base(root: &Path, worktree: &Path, key: &str) -> Option<String> {
    let (repo, tree) = write_tree(root, worktree, &format!("base-{key}"), &[])
        .map_err(|e| tracing::warn!("base snapshot not taken: {e}"))
        .ok()?;
    let stem = repo.file_stem()?.to_string_lossy().into_owned();
    git(
        &repo,
        None,
        None,
        &["update-ref", &format!("refs/drgnx/base/{stem}"), &tree],
    )
    .ok()?;
    Some(tree)
}

/// What one file changed against the base.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileCount {
    pub path: String,
    pub plus: u32,
    pub minus: u32,
    /// The file is not in the base at all (a new file).
    pub untracked: bool,
}

/// The commit WORKTREE's `HEAD` names, from its ref files: `HEAD`, then the loose ref, then `packed-refs`, each read
/// through `eitri` (a link in any component and a FIFO are refused at once).  A `.git` file (a linked worktree) is
/// followed through its `gitdir:` and that folder's `commondir`.  Runs no git.  An agent writes these files, so a ref
/// name must stay under `refs/` and only a full hex object id is ever answered: a hint, checked before use.
pub fn head_of(worktree: &Path) -> Option<String> {
    use eitri::{Kind, open_beneath, open_path, read_regular};
    use std::os::fd::{AsFd, BorrowedFd};
    const MAX: u64 = 1 << 20;
    let text = |dir: BorrowedFd<'_>, rel: &str| -> Option<String> {
        String::from_utf8(read_regular(dir, Path::new(rel), MAX).ok()?).ok()
    };
    let is_id = |s: &str| matches!(s.len(), 40 | 64) && s.bytes().all(|b| b.is_ascii_hexdigit());
    let wt = rustix::fs::open(
        worktree,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::DIRECTORY | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .ok()?;
    let dot = open_beneath(wt.as_fd(), Path::new(".git"), Kind::Any).ok()?;
    // the folder HEAD is in, and the one the refs are in (the same unless a linked worktree)
    let (gitdir, common) = if dot.is_dir {
        (dot.fd, None)
    } else {
        let line = text(wt.as_fd(), ".git")?;
        // a relative gitdir is read from the worktree's own place: `open_path` refuses a link in any component, and
        // the folder the hub was told (`/tmp`, `/var` on macOS) may lie behind one
        let base = std::fs::canonicalize(worktree).unwrap_or_else(|_| worktree.to_owned());
        let to = base.join(line.trim_end().strip_prefix("gitdir: ")?);
        let gitdir = open_path(&to, Kind::Dir).ok()?.fd;
        let common = text(gitdir.as_fd(), "commondir")
            .and_then(|c| open_path(&to.join(c.trim_end()), Kind::Dir).ok());
        (gitdir, common.map(|p| p.fd))
    };
    let refs = common.as_ref().unwrap_or(&gitdir).as_fd();
    let head = text(gitdir.as_fd(), "HEAD")?;
    let head = head.trim_end();
    let id = match head.strip_prefix("ref: ") {
        None => head.to_string(),
        Some(name) => {
            let parts: Vec<&str> = name.split('/').collect();
            if parts.len() < 2
                || parts[0] != "refs"
                || parts
                    .iter()
                    .any(|p| p.is_empty() || *p == "." || *p == "..")
            {
                return None;
            }
            match text(refs, name) {
                Some(t) => t.trim_end().to_string(),
                None => text(refs, "packed-refs")?.lines().find_map(|l| {
                    let (sha, n) = l.split_once(' ')?;
                    (n == name).then(|| sha.to_string())
                })?,
            }
        }
    };
    is_id(&id).then_some(id)
}

/// The tree of SID's nearest snapshot at or below step SEQ in WORKTREE's shadow repository (`refs/drgnx/s/<sid>/<n>`
/// with the largest N not above SEQ); none when it has none.
pub fn tree_at(root: &Path, worktree: &Path, sid: &str, seq: i64) -> Option<String> {
    let repo = repo_of(root, worktree);
    if !repo.join("HEAD").exists() {
        return None;
    }
    let prefix = format!("refs/drgnx/s/{}/", safe(sid));
    let out = git(
        &repo,
        None,
        None,
        &["for-each-ref", "--format=%(refname) %(objectname)", &prefix],
    )
    .ok()?;
    out.lines()
        .filter_map(|l| {
            let (name, id) = l.split_once(' ')?;
            let n: i64 = name.strip_prefix(&prefix)?.parse().ok()?;
            (n <= seq).then(|| (n, id.to_string()))
        })
        .max_by_key(|(n, _)| *n)
        .map(|(_, id)| id)
}

/// One path that differs between two trees: each side's git mode (0: not there) and the TO side's blob.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeChange {
    pub path: PathBuf,
    pub from_mode: u32,
    pub to_mode: u32,
    pub to_blob: Option<String>,
}

/// The paths that differ between FROM and TO of WORKTREE's shadow repository, with both sides' modes
/// (`diff-tree -r -z --raw --no-renames`, in the shadow repository only: the worktree is never looked at).
pub fn changed(
    root: &Path,
    worktree: &Path,
    from: &str,
    to: &str,
) -> Result<Vec<TreeChange>, String> {
    use std::os::unix::ffi::OsStrExt;
    let repo = repo_of(root, worktree);
    let out = git_bytes(
        &repo,
        None,
        None,
        &["diff-tree", "-r", "-z", "--raw", "--no-renames", from, to],
    )?;
    // ":<from mode> <to mode> <from blob> <to blob> <status>\0<path>\0" per path
    let mut it = out.split(|b| *b == 0);
    let mut v = Vec::new();
    while let Some(meta) = it.next() {
        if meta.is_empty() {
            continue;
        }
        let Some(path) = it.next() else {
            break;
        };
        let meta = String::from_utf8_lossy(meta);
        let f: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
        let [from_mode, to_mode, _, to_blob, _] = f[..] else {
            return Err(format!("diff-tree: an unknown line {meta:?}"));
        };
        let mode = |m: &str| u32::from_str_radix(m, 8).unwrap_or(0);
        let to_mode = mode(to_mode);
        v.push(TreeChange {
            path: PathBuf::from(std::ffi::OsStr::from_bytes(path)),
            from_mode: mode(from_mode),
            to_mode,
            to_blob: (to_mode != 0).then(|| to_blob.to_string()),
        });
    }
    Ok(v)
}

/// What a restore did: the paths written or removed, and those left with the reason (`protected`, `gitlink`, or
/// what the write said).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Restored {
    pub written: Vec<PathBuf>,
    pub skipped: Vec<(PathBuf, String)>,
}

/// REL's missing folders made beneath DIR, one component at a time through `eitri` (a link in any is refused).
fn make_parents(dir: std::os::fd::BorrowedFd<'_>, rel: &Path) -> Result<(), eitri::FsError> {
    use eitri::{FsError, Kind, open_beneath};
    use std::os::fd::AsFd;
    let Some(parent) = rel.parent() else {
        return Ok(());
    };
    let mut at = PathBuf::new();
    for c in parent.components() {
        let next = at.join(c);
        match open_beneath(dir, &next, Kind::Dir) {
            Ok(_) => {}
            Err(FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                let here = if at.as_os_str().is_empty() {
                    Path::new(".")
                } else {
                    at.as_path()
                };
                let base = open_beneath(dir, here, Kind::Dir)?;
                rustix::fs::mkdirat(
                    base.fd.as_fd(),
                    c.as_os_str(),
                    rustix::fs::Mode::from_raw_mode(0o755),
                )
                .map_err(FsError::from)?;
            }
            Err(e) => return Err(e),
        }
        at = next;
    }
    Ok(())
}

/// What TARGET holds now, written as a tree into SOURCE's shadow repository under ROOT (an index of TARGET's own; git
/// runs in the shadow repository only, with TARGET as its work tree), less the secret files and EXTRA.
pub fn tree_now(
    root: &Path,
    source: &Path,
    target: &Path,
    extra: &[String],
) -> Result<String, String> {
    let key = repo_of(Path::new(""), target)
        .to_string_lossy()
        .trim_end_matches(".git")
        .to_string();
    write_tree_in(
        &repo_of(root, source),
        target,
        &format!("restore-{key}"),
        extra,
    )
}

/// TREE kept as the ref NAME (`refs/drgnx/…`) of WORKTREE's shadow repository under ROOT, so it is never pruned.
pub fn keep(root: &Path, worktree: &Path, name: &str, tree: &str) -> Result<(), String> {
    git(
        &repo_of(root, worktree),
        None,
        None,
        &["update-ref", name, tree],
    )
    .map(drop)
}

/// TARGET made equal to tree TO of SOURCE's shadow repository under ROOT (ONLY: just those paths), by mode: a regular
/// file through `eitri::write_regular` with its mode, a link (`120000`) through `eitri::symlink_beneath` with its
/// target as bytes, a path TO lacks through `eitri::remove_beneath`; a gitlink (`160000`) is skipped and listed, and so
/// is every path [`crate::history::tree::restorable`] refuses (EXTRA: the secret paths the snapshots left out).  What
/// TARGET holds now is first written as a tree into the same shadow repository (git runs there only, with TARGET as
/// its work tree, as a snapshot does).  Nothing is chmodded through a path; a write that fails is listed, not fatal.
pub fn restore_into(
    root: &Path,
    source: &Path,
    target: &Path,
    to: &str,
    only: Option<&[PathBuf]>,
    extra: &[String],
) -> Result<Restored, String> {
    use std::os::fd::AsFd;
    let repo = repo_of(root, source);
    let now = tree_now(root, source, target, extra)?;
    let changes = changed(root, source, &now, to)?;
    let dir = rustix::fs::open(
        target,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::DIRECTORY | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|e| format!("{}: {e}", target.display()))?;
    let dir = dir.as_fd();
    let mut r = Restored::default();
    for c in changes {
        if only.is_some_and(|o| !o.contains(&c.path)) {
            continue;
        }
        if !crate::history::tree::restorable(&c.path, extra) {
            r.skipped.push((c.path, "protected".into()));
            continue;
        }
        let bytes = || -> Result<Vec<u8>, eitri::FsError> {
            let blob = c.to_blob.as_deref().unwrap_or_default();
            git_bytes(&repo, None, None, &["cat-file", "blob", blob])
                .map_err(|e| eitri::FsError::Io(std::io::Error::other(e)))
        };
        let done = match c.to_mode {
            0 => eitri::remove_beneath(dir, &c.path),
            0o100644 | 0o100755 => bytes().and_then(|b| {
                make_parents(dir, &c.path)?;
                eitri::write_regular(dir, &c.path, &b, c.to_mode & 0o777)
            }),
            0o120000 => bytes().and_then(|b| {
                make_parents(dir, &c.path)?;
                eitri::symlink_beneath(dir, &c.path, &b)
            }),
            0o160000 => {
                r.skipped.push((c.path, "gitlink".into()));
                continue;
            }
            m => {
                r.skipped.push((c.path, format!("mode {m:o}")));
                continue;
            }
        };
        match done {
            Ok(()) => r.written.push(c.path),
            Err(e) => r.skipped.push((c.path, e.to_string())),
        }
    }
    Ok(r)
}

/// Bytes under DIR (files only).
fn size_of(dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return 0;
    };
    rd.flatten()
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => size_of(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

/// The size of REPOS together.
pub fn size(repos: &[PathBuf]) -> u64 {
    repos.iter().map(|r| size_of(r)).sum()
}

/// Bring REPOS (a project's shadow repositories) under CAP bytes: the refs of FINISHED sessions (oldest first) go one
/// session at a time, then the repositories are collected (`git gc --prune=now`).  A running session's refs are never
/// removed: over the cap with no finished session left answers [`Pruned::Stop`].
pub fn prune(repos: &[PathBuf], cap: u64, finished: &[String]) -> Pruned {
    if size(repos) <= cap {
        return Pruned::Fits;
    }
    let mut gone = Vec::new();
    for sid in finished {
        let prefix = format!("refs/drgnx/s/{}/", safe(sid));
        let mut any = false;
        for repo in repos {
            let Ok(refs) = git(
                repo,
                None,
                None,
                &["for-each-ref", "--format=%(refname)", &prefix],
            ) else {
                continue;
            };
            for r in refs.lines().filter(|l| !l.is_empty()) {
                any |= git(repo, None, None, &["update-ref", "-d", r]).is_ok();
            }
            let _ = git(repo, None, None, &["update-ref", "-d", &turn_ref(sid)]);
            if let Ok(held) = git(
                repo,
                None,
                None,
                &["for-each-ref", "--format=%(refname)", &write_refs(sid)],
            ) {
                for r in held.lines().filter(|l| !l.is_empty()) {
                    let _ = git(repo, None, None, &["update-ref", "-d", r]);
                }
            }
            let _ = std::fs::remove_file(repo.join(format!("index-{}", safe(sid))));
            for key in [
                format!("turn-{sid}"),
                format!("write-{sid}"),
                format!("wheel-{sid}"),
                format!("diff-{sid}"),
            ] {
                let _ = std::fs::remove_file(repo.join(format!("index-{}", safe(&key))));
            }
        }
        if !any {
            continue;
        }
        gone.push(sid.clone());
        for repo in repos {
            let _ = git(repo, None, None, &["gc", "-q", "--prune=now"]);
        }
        if size(repos) <= cap {
            return Pruned::Freed(gone);
        }
    }
    if gone.is_empty() {
        Pruned::Stop
    } else if size(repos) <= cap {
        Pruned::Freed(gone)
    } else {
        Pruned::Stop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Bytes git cannot compress much.
    fn noise(seed: u64, n: usize) -> Vec<u8> {
        let mut x = seed | 1;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 24) as u8
            })
            .collect()
    }

    fn listing(repo: &Path, tree: &str) -> Vec<String> {
        git(repo, None, None, &["ls-tree", "-r", "--name-only", tree])
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect()
    }

    #[test]
    fn timeline_snapshot_after_an_edit() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "one").unwrap();
        let t1 = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::write(wt.join("a.txt"), "two").unwrap();
        let t2 = take(&root, &wt, "s1", 2, &[]).unwrap();
        assert_ne!(t1, t2);
        let repo = repo_of(&root, &wt);
        assert_eq!(
            git(&repo, None, None, &["rev-parse", "refs/drgnx/s/s1/1"]).unwrap(),
            t1
        );
        assert_eq!(
            git(&repo, None, None, &["rev-parse", "refs/drgnx/s/s1/2"]).unwrap(),
            t2
        );
        assert_eq!(listing(&repo, &t2), ["a.txt"]);
        // the same content again is the same tree
        assert_eq!(take(&root, &wt, "s1", 3, &[]).unwrap(), t2);
    }

    /// Pattern D: the base is kept as a ref of its own.
    #[test]
    fn the_base_is_a_ref_of_its_own() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "one\n").unwrap();
        let base = take_base(&root, &wt, "job/1-1").unwrap();
        // the base is kept as a ref of its own, which a prune leaves alone
        let repo = repo_of(&root, &wt);
        let stem = repo.file_stem().unwrap().to_string_lossy().into_owned();
        assert_eq!(
            git(
                &repo,
                None,
                None,
                &["rev-parse", &format!("refs/drgnx/base/{stem}")]
            )
            .unwrap(),
            base
        );
    }

    #[test]
    fn timeline_snapshot_skips_secret_files() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        for f in [
            "a.txt",
            ".env",
            "sub/.env",
            "sub/.npmrc",
            "secrets.env",
            "x.pem",
            "keep/own-secret.txt",
        ] {
            let p = wt.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "x").unwrap();
        }
        let t = take(&root, &wt, "s1", 1, &["keep/own-secret.txt".into()]).unwrap();
        assert_eq!(listing(&repo_of(&root, &wt), &t), ["a.txt"]);
    }

    #[test]
    fn timeline_cap_prunes_finished_first() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("big"), noise(1, 60_000)).unwrap();
        take(&root, &wt, "old", 1, &[]).unwrap();
        std::fs::write(wt.join("big"), noise(2, 60_000)).unwrap();
        take(&root, &wt, "live", 1, &[]).unwrap();
        let repos = vec![repo_of(&root, &wt)];
        let before = size(&repos);
        assert_eq!(prune(&repos, before, &["old".into()]), Pruned::Fits);
        assert_eq!(
            prune(&repos, before - 30_000, &["old".into()]),
            Pruned::Freed(vec!["old".into()])
        );
        assert!(size(&repos) < before - 30_000);
        let refs = git(
            &repos[0],
            None,
            None,
            &["for-each-ref", "--format=%(refname)"],
        )
        .unwrap();
        assert_eq!(refs, "refs/drgnx/s/live/1");
    }

    /// Plain git in DIR, for the fixtures only (never the code under test), with no outside config.
    fn fixture_git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(["-c", "init.defaultBranch=main"])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// A repository at DIR with one commit on `main`; the commit's id.
    fn repo_with_a_commit(dir: &Path) -> String {
        std::fs::create_dir_all(dir).unwrap();
        fixture_git(dir, &["init", "-q", "."]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        fixture_git(dir, &["add", "a.txt"]);
        fixture_git(dir, &["commit", "-q", "-m", "one"]);
        fixture_git(dir, &["rev-parse", "HEAD"])
    }

    fn mkfifo(p: &Path) {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(p.as_os_str().as_bytes()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    }

    /// Pattern D: the branch's loose ref, then (after `pack-refs`) `packed-refs`, a newer loose ref over a packed one,
    /// then a detached `HEAD`; no repository answers None.
    #[test]
    fn head_of_reads_loose_and_packed_refs() {
        let d = tempfile::tempdir().unwrap();
        let wt = d.path().join("wt");
        let one = repo_with_a_commit(&wt);
        assert!(wt.join(".git/refs/heads/main").is_file());
        assert_eq!(head_of(&wt).as_deref(), Some(one.as_str()));
        fixture_git(&wt, &["pack-refs", "--all"]);
        assert!(
            !wt.join(".git/refs/heads/main").exists(),
            "the ref is packed"
        );
        assert_eq!(head_of(&wt).as_deref(), Some(one.as_str()));
        std::fs::write(wt.join("a.txt"), "two\n").unwrap();
        fixture_git(&wt, &["commit", "-q", "-am", "two"]);
        let two = fixture_git(&wt, &["rev-parse", "HEAD"]);
        assert_eq!(head_of(&wt).as_deref(), Some(two.as_str()));
        fixture_git(&wt, &["checkout", "-q", "--detach", &one]);
        assert_eq!(head_of(&wt).as_deref(), Some(one.as_str()));
        assert_eq!(head_of(&d.path().join("none")), None);
    }

    /// The variable that makes [`head_of_in_a_child_without_path`] read a worktree.
    const CHILD: &str = "DRGNX_TEST_HEAD_OF_IN";

    /// Pattern D: the read runs in a child of this test binary whose PATH is empty, so no git could be found, and still
    /// answers the commit.
    #[test]
    fn head_of_never_runs_git() {
        let d = tempfile::tempdir().unwrap();
        let wt = d.path().join("wt");
        let one = repo_with_a_commit(&wt);
        let out = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "timeline::snapshot::tests::head_of_in_a_child_without_path",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("PATH", "")
            .env(CHILD, &wt)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(
            out.status.success(),
            "{stdout}{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(stdout.contains(&format!("head={one}\n")), "{stdout}");
    }

    /// Pattern D: [`head_of_never_runs_git`]'s child; on its own it has nothing to read.
    #[test]
    fn head_of_in_a_child_without_path() {
        if let Some(wt) = std::env::var_os(CHILD) {
            assert_eq!(std::env::var_os("PATH").unwrap_or_default(), "");
            println!("head={}", head_of(Path::new(&wt)).unwrap_or_default());
        }
    }

    /// Pattern D with a hang guard (a pass never waits): `.git` as a link to a good repository's, `HEAD` as a link to a
    /// good `HEAD`, the branch's loose ref as a link, and `HEAD` as a FIFO all answer None, the FIFO at once.
    #[test]
    fn head_of_refuses_a_link_and_a_fifo() {
        use std::os::unix::fs::symlink;
        let d = tempfile::tempdir().unwrap();
        let good = d.path().join("good");
        let one = repo_with_a_commit(&good);
        assert_eq!(head_of(&good).as_deref(), Some(one.as_str()), "the control");
        let linked = d.path().join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        symlink(good.join(".git"), linked.join(".git")).unwrap();
        assert_eq!(head_of(&linked), None, ".git a link");
        let wt = d.path().join("wt");
        repo_with_a_commit(&wt);
        std::fs::remove_file(wt.join(".git/HEAD")).unwrap();
        symlink(good.join(".git/HEAD"), wt.join(".git/HEAD")).unwrap();
        assert_eq!(head_of(&wt), None, "HEAD a link");
        std::fs::remove_file(wt.join(".git/HEAD")).unwrap();
        std::fs::write(wt.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::remove_file(wt.join(".git/refs/heads/main")).unwrap();
        symlink(
            good.join(".git/refs/heads/main"),
            wt.join(".git/refs/heads/main"),
        )
        .unwrap();
        assert_eq!(head_of(&wt), None, "the loose ref a link");
        std::fs::remove_file(wt.join(".git/HEAD")).unwrap();
        mkfifo(&wt.join(".git/HEAD"));
        let (tx, rx) = std::sync::mpsc::channel();
        let p = wt.clone();
        std::thread::spawn(move || tx.send(head_of(&p)).unwrap());
        let got = rx
            .recv_timeout(std::time::Duration::from_secs(60))
            .expect("a FIFO at HEAD blocked the read");
        assert_eq!(got, None);
    }

    /// Pattern D: a linked worktree's `.git` file is followed to its folder in the main repository: `HEAD` is read
    /// there and the branch's ref in the common folder, loose and then packed.
    #[test]
    fn head_of_reads_a_linked_worktree() {
        let d = tempfile::tempdir().unwrap();
        // git records the real path (`/private/var` on macOS), so the fixture lives there too
        let root = std::fs::canonicalize(d.path()).unwrap();
        let (main, wt) = (root.join("main"), root.join("wt"));
        let one = repo_with_a_commit(&main);
        fixture_git(
            &main,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
        );
        assert!(wt.join(".git").is_file());
        std::fs::write(wt.join("b.txt"), "b\n").unwrap();
        fixture_git(&wt, &["add", "b.txt"]);
        fixture_git(&wt, &["commit", "-q", "-m", "b"]);
        let feat = fixture_git(&wt, &["rev-parse", "HEAD"]);
        assert_ne!(feat, one);
        assert_eq!(head_of(&wt).as_deref(), Some(feat.as_str()));
        assert_eq!(head_of(&main).as_deref(), Some(one.as_str()));
        fixture_git(&main, &["pack-refs", "--all"]);
        assert_eq!(head_of(&wt).as_deref(), Some(feat.as_str()));
    }

    /// Pattern D: a worktree reached through a link (`/tmp` is `/private/tmp` on macOS) with a relative `gitdir` is
    /// still read: the link is in the path the hub was given, not in the `.git` file.
    #[test]
    fn head_of_reads_a_linked_worktree_given_through_a_link() {
        let d = tempfile::tempdir().unwrap();
        let (main, wt) = (d.path().join("main"), d.path().join("real/wt"));
        std::fs::create_dir_all(wt.parent().unwrap()).unwrap();
        let one = repo_with_a_commit(&main);
        fixture_git(
            &main,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
        );
        let rel = std::fs::canonicalize(&main)
            .unwrap()
            .join(".git/worktrees/wt");
        let up = pathdiff(&rel, &std::fs::canonicalize(&wt).unwrap());
        std::fs::write(wt.join(".git"), format!("gitdir: {up}\n")).unwrap();
        let link = d.path().join("link");
        std::os::unix::fs::symlink(d.path().join("real"), &link).unwrap();
        assert_eq!(head_of(&link.join("wt")).as_deref(), Some(one.as_str()));
    }

    /// `to` as a path relative to the folder `from`, both canonical.
    fn pathdiff(to: &Path, from: &Path) -> String {
        let (t, f): (Vec<_>, Vec<_>) = (
            to.components().collect::<Vec<_>>(),
            from.components().collect::<Vec<_>>(),
        );
        let n = t.iter().zip(&f).take_while(|(a, b)| a == b).count();
        let mut out: Vec<String> = f[n..].iter().map(|_| "..".to_owned()).collect();
        out.extend(
            t[n..]
                .iter()
                .map(|c| c.as_os_str().to_string_lossy().into_owned()),
        );
        out.join("/")
    }

    /// Pattern D: what an agent points these files at never reaches the record: `.git` naming a text file or a folder
    /// whose `HEAD` is text, `HEAD` naming a file outside `refs/` or through `..`, and a ref file holding text.
    #[test]
    fn head_of_keeps_only_an_object_id() {
        let d = tempfile::tempdir().unwrap();
        let notes = d.path().join("notes.txt");
        std::fs::write(&notes, "a private note\n").unwrap();
        let wt = d.path().join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", notes.display())).unwrap();
        assert_eq!(head_of(&wt), None, "gitdir a text file");
        let fake = d.path().join("fake");
        std::fs::create_dir_all(&fake).unwrap();
        std::fs::copy(&notes, fake.join("HEAD")).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", fake.display())).unwrap();
        assert_eq!(head_of(&wt), None, "HEAD text");
        let r = d.path().join("r");
        let one = repo_with_a_commit(&r);
        // an object id where no ref may be, so only the name checks keep it out
        std::fs::write(r.join(".git/sneaky"), format!("{one}\n")).unwrap();
        std::fs::write(r.join(".git/refs/heads/text"), "a private note\n").unwrap();
        for head in [
            "ref: sneaky",
            "ref: refs/../sneaky",
            "ref: refs/heads/../../sneaky",
            "ref: /etc/passwd",
            "ref: refs/heads/text",
            "0123abc",
        ] {
            std::fs::write(r.join(".git/HEAD"), format!("{head}\n")).unwrap();
            assert_eq!(head_of(&r), None, "{head}");
        }
        std::fs::write(r.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        assert_eq!(head_of(&r).as_deref(), Some(one.as_str()), "the control");
    }

    #[test]
    fn timeline_cap_with_nothing_finished_stops_with_a_notice() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("big"), noise(3, 60_000)).unwrap();
        take(&root, &wt, "live", 1, &[]).unwrap();
        let repos = vec![repo_of(&root, &wt)];
        assert_eq!(prune(&repos, 1_000, &[]), Pruned::Stop);
        let refs = git(
            &repos[0],
            None,
            None,
            &["for-each-ref", "--format=%(refname)"],
        )
        .unwrap();
        assert_eq!(refs, "refs/drgnx/s/live/1");
    }

    /// Pattern D: the tree taken before a write is held by a ref of its own until a step keeps it, then only the step's
    /// ref holds it; a finished session's held trees go with its refs at the cap.
    #[test]
    fn write_tree_before_is_held_until_its_step_keeps_it() {
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("a.txt"), "agent").unwrap();
        let t = write_tree_before(&root, &wt, "s1").unwrap();
        let repo = repo_of(&root, &wt);
        let refs = || git(&repo, None, None, &["for-each-ref", "--format=%(refname)"]).unwrap();
        assert_eq!(refs(), format!("refs/drgnx/write/s1/{t}"));
        std::fs::write(wt.join("b.txt"), "next").unwrap();
        put_write_tree(&root, &wt, "s1", 3, &t).unwrap();
        assert_eq!(refs(), "refs/drgnx/s/s1/3");
        assert_eq!(listing(&repo, &t), ["a.txt"], "taken before b.txt");
        let held = write_tree_before(&root, &wt, "s1").unwrap();
        assert_ne!(held, t);
        // a cap of 0 bytes: every finished session's refs go (and the snapshots then stop)
        prune(std::slice::from_ref(&repo), 0, &["s1".into()]);
        assert_eq!(refs(), "");
    }

    /// The cost of the tree taken before a write, per write, with one file changed each time and the index warm.
    #[test]
    #[ignore = "timing: prints what the tree before a write costs"]
    fn write_tree_before_cost() {
        use std::time::Instant;
        for n in [100usize, 1_000, 10_000] {
            let d = tempfile::tempdir().unwrap();
            let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
            for i in 0..n {
                let p = wt.join(format!("d{}/f{i}.txt", i / 100));
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                std::fs::write(p, format!("line {i}\n")).unwrap();
            }
            write_tree_before(&root, &wt, "s1").unwrap();
            let runs = 20;
            let t = Instant::now();
            for i in 0..runs {
                std::fs::write(wt.join("d0/f0.txt"), format!("write {i}\n")).unwrap();
                write_tree_before(&root, &wt, "s1").unwrap();
            }
            let ms = t.elapsed().as_secs_f64() * 1000.0 / f64::from(runs);
            println!("COST tree before a write, {n} files: {ms:.2} ms per write");
        }
    }

    /// Pattern D: an added, a modified, a deleted file and a mode change, each with both sides' git modes, read in
    /// the shadow repository only; and the nearest snapshot at or below a step.
    #[test]
    fn changed_reports_add_modify_delete_and_modes() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let (root, wt) = (d.path().join("cp"), d.path().join("wt"));
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join("edit.txt"), "one").unwrap();
        std::fs::write(wt.join("gone.txt"), "x").unwrap();
        std::fs::write(wt.join("run.sh"), "echo").unwrap();
        let t1 = take(&root, &wt, "s1", 1, &[]).unwrap();
        std::fs::write(wt.join("edit.txt"), "two").unwrap();
        std::fs::remove_file(wt.join("gone.txt")).unwrap();
        std::fs::write(wt.join("new.txt"), "n").unwrap();
        std::fs::set_permissions(wt.join("run.sh"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        std::os::unix::fs::symlink("edit.txt", wt.join("link")).unwrap();
        let t3 = take(&root, &wt, "s1", 3, &[]).unwrap();
        let mut got = changed(&root, &wt, &t1, &t3).unwrap();
        got.sort_by(|a, b| a.path.cmp(&b.path));
        let modes: Vec<(&str, u32, u32, bool)> = got
            .iter()
            .map(|c| {
                (
                    c.path.to_str().unwrap(),
                    c.from_mode,
                    c.to_mode,
                    c.to_blob.is_some(),
                )
            })
            .collect();
        assert_eq!(
            modes,
            [
                ("edit.txt", 0o100644, 0o100644, true),
                ("gone.txt", 0o100644, 0, false),
                ("link", 0, 0o120000, true),
                ("new.txt", 0, 0o100644, true),
                ("run.sh", 0o100644, 0o100755, true),
            ]
        );
        let edit = got
            .iter()
            .find(|c| c.path == Path::new("edit.txt"))
            .unwrap();
        assert_eq!(
            blob(&root, &wt, &t3, "edit.txt").unwrap(),
            git_bytes(
                &repo_of(&root, &wt),
                None,
                None,
                &["cat-file", "blob", edit.to_blob.as_deref().unwrap()]
            )
            .unwrap()
        );
        // the nearest snapshot at or below a step: 2 has none of its own
        assert_eq!(tree_at(&root, &wt, "s1", 2).as_deref(), Some(t1.as_str()));
        assert_eq!(tree_at(&root, &wt, "s1", 3).as_deref(), Some(t3.as_str()));
        assert_eq!(tree_at(&root, &wt, "s1", 0), None);
        assert_eq!(tree_at(&root, &wt, "s2", 3), None);
    }
}
