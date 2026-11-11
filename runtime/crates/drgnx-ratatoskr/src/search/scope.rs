//! The Search view's git scopes: which files Changed, Staged and Branch search, and for "changed lines only" (`±`)
//! the added-side line ranges of each file's diff. Read with the trusted git (`draugr::git`): one
//! `status --porcelain=v2 -z` for Changed and Staged, `merge-base` and `diff --raw -z` for Branch, `diff -U0` for the
//! lines. The content searched is always the working tree's.
//!
//! A git child, not gix: the workspace's gix has `index` and `dirwalk` but not `status` (whose feature pulls more
//! crates), and Branch needs `merge-base` and a diff anyway; a status of the drgnx checkout takes a few milliseconds.

use draugr::git::{GitCall, Place, command, git_program};
use runstav::methods::search::{ScopeBases, ScopeKind};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// git's empty tree: what an unborn branch's files are taken against.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
/// How many branches the Branch menu lists.
const RECENT_BASES: usize = 20;

/// The files a git scope searches, found when the search starts.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct FileList {
    /// The repository's top level (a linked worktree's own).
    pub top: PathBuf,
    /// Absolute paths, sorted; a rename at its new path.
    pub files: Vec<PathBuf>,
    /// Submodules in the scope: not searched, counted.
    pub submodules: usize,
    /// Deleted files in the scope: nothing to search, counted.
    pub deleted: usize,
    /// Branch: the base it was taken against.
    pub base: Option<String>,
    /// What the added lines are taken against: a commit (HEAD, the merge base), or none for the index (Staged).
    pub against: Option<String>,
    /// Files of the list with changes in the working tree that are not staged (Staged's `±` falls back for them).
    pub unstaged: HashSet<PathBuf>,
    /// Files with no committed version (untracked, or added in the index): every line is changed.
    pub new: HashSet<PathBuf>,
    /// Why the list is empty, for the status line.
    pub why_empty: Option<String>,
}

/// Why a scope has no list.
#[derive(Debug, Clone, PartialEq)]
pub enum ScopeError {
    /// The folder is not in a git repository.
    NotARepo,
    /// Branch has no default base (detached HEAD, an unborn branch, no upstream, `main` or `master`): it asks.
    NeedsBase(String),
    /// Git refused or failed: its first line.
    Git(String),
}

impl std::fmt::Display for ScopeError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            ScopeError::NotARepo => f.write_str("not in a git repository"),
            ScopeError::NeedsBase(why) => write!(f, "choose a base: {why}"),
            ScopeError::Git(e) => f.write_str(e),
        }
    }
}

/// The lines of one file a `±` search keeps: the added side of its diff's hunks.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Added {
    /// 1-based inclusive line ranges.
    pub ranges: Vec<(u32, u32)>,
    /// The file is new: every line counts.
    pub whole: bool,
    /// Staged only: the file has unstaged changes, so these are the working tree's hunks, not the index's.
    pub fell_back: bool,
}

impl Added {
    /// Whether a match over lines START..=END intersects an added range.
    pub fn keeps(&self, start: u32, end: u32) -> bool {
        self.whole || self.ranges.iter().any(|&(a, b)| a <= end && start <= b)
    }
}

/// `git ARGS` in DIR with the trusted git, read-only: its output, or its first line of complaint.
fn git<S: AsRef<std::ffi::OsStr>>(dir: &Path, args: &[S]) -> Result<Vec<u8>, ScopeError> {
    let program = git_program().map_err(|e| ScopeError::Git(e.to_string()))?;
    let call = GitCall {
        place: Place::Trusted { read_only: true },
        allow_protocols: vec![],
        args: args.iter().map(|a| a.as_ref().to_owned()).collect(),
    };
    let (argv, env) = command(&call).map_err(|e| ScopeError::Git(format!("{e:?}")))?;
    let out = Command::new(&program.path)
        .args(argv)
        .envs(env)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .current_dir(dir)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| ScopeError::Git(e.to_string()))?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let first = err.lines().next().unwrap_or("git failed").to_owned();
        if first.contains("not a git repository") {
            Err(ScopeError::NotARepo)
        } else {
            Err(ScopeError::Git(first))
        }
    }
}

/// One line of output, trimmed; none when git answered nothing or failed.
fn git_line(dir: &Path, args: &[&str]) -> Option<String> {
    let out = git(dir, args).ok()?;
    let s = String::from_utf8_lossy(&out).trim().to_owned();
    (!s.is_empty()).then_some(s)
}

/// DIR's repository's top level.
fn toplevel(dir: &Path) -> Result<PathBuf, ScopeError> {
    let out = git(dir, &["rev-parse", "--show-toplevel"])?;
    let top = out.strip_suffix(b"\n").unwrap_or(&out);
    if top.is_empty() {
        return Err(ScopeError::NotARepo);
    }
    Ok(PathBuf::from(OsString::from_vec(top.to_vec())))
}

/// One entry of `status --porcelain=v2 -z`.
struct Entry {
    path: Vec<u8>,
    /// The index's and the working tree's letters (`?` `?` for untracked).
    x: u8,
    y: u8,
    submodule: bool,
}

/// The entries of a v2 status OUT (no headers asked for, no ignored).
fn parse_status(out: &[u8]) -> Vec<Entry> {
    let mut entries = Vec::new();
    let mut it = out.split(|&b| b == 0);
    while let Some(rec) = it.next() {
        let fields = |n: usize| rec.splitn(n, |&b| b == b' ').collect::<Vec<_>>();
        match rec.first() {
            Some(b'?') => entries.push(Entry {
                path: rec.get(2..).unwrap_or_default().to_vec(),
                x: b'?',
                y: b'?',
                submodule: false,
            }),
            Some(b'1') | Some(b'2') | Some(b'u') => {
                let n = match rec[0] {
                    b'1' => 9,
                    b'2' => 10,
                    _ => 11,
                };
                let f = fields(n);
                if f.len() < n {
                    continue;
                }
                let xy = f[1];
                entries.push(Entry {
                    path: f[n - 1].to_vec(),
                    x: xy.first().copied().unwrap_or(b'.'),
                    y: xy.get(1).copied().unwrap_or(b'.'),
                    submodule: f[2].first() == Some(&b'S'),
                });
                if rec[0] == b'2' {
                    it.next(); // the original path of a rename
                }
            }
            _ => {}
        }
    }
    entries
}

/// The path under TOP that git names REL.
fn under(top: &Path, rel: &[u8]) -> PathBuf {
    top.join(std::ffi::OsStr::from_bytes(rel))
}

/// The files of DIR's repository that KIND (Changed, Staged or Branch) searches; BASE is Branch's chosen base.
pub fn files(dir: &Path, kind: ScopeKind, base: Option<&str>) -> Result<FileList, ScopeError> {
    let top = toplevel(dir)?;
    let status = parse_status(&git(
        &top,
        &["status", "--porcelain=v2", "-z", "--untracked-files=all"],
    )?);
    let mut l = FileList {
        top: top.clone(),
        ..FileList::default()
    };
    let mut files = BTreeSet::new();
    match kind {
        ScopeKind::Changed | ScopeKind::Staged => {
            let staged = kind == ScopeKind::Staged;
            for e in &status {
                if staged && matches!(e.x, b'.' | b'?') {
                    continue;
                }
                if e.submodule {
                    l.submodules += 1;
                } else if e.x == b'D' || (!staged && e.y == b'D') {
                    l.deleted += 1;
                } else {
                    let p = under(&top, &e.path);
                    if matches!(e.x, b'A' | b'?') {
                        l.new.insert(p.clone());
                    }
                    if e.y != b'.' {
                        l.unstaged.insert(p.clone());
                    }
                    files.insert(p);
                }
            }
            l.against = if staged {
                None
            } else if git_line(&top, &["rev-parse", "--verify", "-q", "HEAD"]).is_some() {
                Some("HEAD".into())
            } else {
                Some(EMPTY_TREE.into())
            };
            if files.is_empty() {
                l.why_empty = Some(
                    if staged {
                        "nothing staged"
                    } else {
                        "no changes in the working tree"
                    }
                    .into(),
                );
            }
        }
        ScopeKind::Branch => {
            let base = match base {
                Some(b) => b.to_owned(),
                None => default_base(&top)?,
            };
            let mb = git_line(&top, &["merge-base", "HEAD", &base])
                .ok_or_else(|| ScopeError::Git(format!("HEAD and {base} have no merge base")))?;
            let raw = git(&top, &["diff", "--raw", "-z", "-M", "--no-ext-diff", &mb])?;
            let mut it = raw.split(|&b| b == 0);
            while let Some(head) = it.next() {
                let Some(meta) = head.strip_prefix(b":") else {
                    continue;
                };
                let f: Vec<&[u8]> = meta.split(|&b| b == b' ').collect();
                let status = f.last().and_then(|s| s.first()).copied().unwrap_or(b'M');
                let mut path = it.next().unwrap_or_default();
                if matches!(status, b'R' | b'C') {
                    path = it.next().unwrap_or_default();
                }
                if f.iter().take(2).any(|m| *m == b"160000") {
                    l.submodules += 1;
                } else if status == b'D' {
                    l.deleted += 1;
                } else {
                    let p = under(&top, path);
                    if status == b'A' {
                        l.new.insert(p.clone());
                    }
                    files.insert(p);
                }
            }
            for e in status.iter().filter(|e| e.x == b'?') {
                let p = under(&top, &e.path);
                l.new.insert(p.clone());
                files.insert(p);
            }
            if files.is_empty() {
                l.why_empty = Some(format!("no changes against {base}"));
            }
            l.base = Some(base);
            l.against = Some(mb);
        }
        ScopeKind::Project | ScopeKind::File | ScopeKind::Open => {
            return Err(ScopeError::Git("not a git scope".into()));
        }
    }
    l.files = files.into_iter().collect();
    Ok(l)
}

/// Branch's base when none is chosen: the upstream, else `main`, else `master`; none on a detached HEAD or an unborn
/// branch.
fn default_base(top: &Path) -> Result<String, ScopeError> {
    if git_line(top, &["symbolic-ref", "-q", "--short", "HEAD"]).is_none() {
        return Err(ScopeError::NeedsBase("HEAD is detached".into()));
    }
    if git_line(top, &["rev-parse", "--verify", "-q", "HEAD"]).is_none() {
        return Err(ScopeError::NeedsBase(
            "the branch has no commits yet".into(),
        ));
    }
    if let Some(up) = upstream(top) {
        return Ok(up);
    }
    for b in ["main", "master"] {
        let r = format!("refs/heads/{b}");
        if git_line(top, &["rev-parse", "--verify", "-q", &r]).is_some() {
            return Ok(b.into());
        }
    }
    Err(ScopeError::NeedsBase("no upstream, main or master".into()))
}

fn upstream(top: &Path) -> Option<String> {
    git_line(
        top,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    )
}

/// The ranges of `diff -U0` OUT, per file under TOP.
fn parse_hunks(top: &Path, out: &[u8]) -> HashMap<PathBuf, Vec<(u32, u32)>> {
    let mut map: HashMap<PathBuf, Vec<(u32, u32)>> = HashMap::new();
    let mut file: Option<PathBuf> = None;
    for line in out.split(|&b| b == b'\n') {
        if let Some(name) = line.strip_prefix(b"+++ ") {
            file = unquote(name)
                .and_then(|n| n.strip_prefix(b"b/").map(<[u8]>::to_vec))
                .map(|n| under(top, &n));
            if let Some(f) = &file {
                map.entry(f.clone()).or_default();
            }
        } else if let (Some(f), Some(h)) = (&file, line.strip_prefix(b"@@ ")) {
            // @@ -a[,b] +c[,d] @@
            let plus = h
                .split(|&b| b == b' ')
                .find_map(|w| w.strip_prefix(b"+"))
                .map(|w| String::from_utf8_lossy(w).into_owned());
            if let Some(plus) = plus {
                let mut it = plus.splitn(2, ',');
                let c: u32 = it.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                let d: u32 = it.next().map_or(Some(1), |s| s.parse().ok()).unwrap_or(0);
                if d > 0 {
                    map.entry(f.clone()).or_default().push((c, c + d - 1));
                }
            }
        }
    }
    map
}

/// A diff header's file name: as it stands, or git's C-quoted form undone; none for `/dev/null`.
fn unquote(name: &[u8]) -> Option<Vec<u8>> {
    let name = name.strip_suffix(b"\t").unwrap_or(name);
    if name == b"/dev/null" {
        return None;
    }
    let Some(inner) = name.strip_prefix(b"\"").and_then(|n| n.strip_suffix(b"\"")) else {
        return Some(name.to_vec());
    };
    let mut out = Vec::with_capacity(inner.len());
    let mut i = 0;
    while i < inner.len() {
        if inner[i] != b'\\' || i + 1 == inner.len() {
            out.push(inner[i]);
            i += 1;
            continue;
        }
        let c = inner[i + 1];
        match c {
            b'0'..=b'7' => {
                let oct = std::str::from_utf8(inner.get(i + 1..i + 4)?).ok()?;
                out.push(u8::from_str_radix(oct, 8).ok()?);
                i += 4;
                continue;
            }
            b'n' => out.push(b'\n'),
            b't' => out.push(b'\t'),
            b'a' => out.push(7),
            b'b' => out.push(8),
            b'f' => out.push(12),
            b'r' => out.push(b'\r'),
            b'v' => out.push(11),
            other => out.push(other),
        }
        i += 2;
    }
    Some(out)
}

/// `diff -U0` of FILES (under TOP) with ARGS before them: each file's added ranges.
fn hunks(
    top: &Path,
    args: &[&str],
    files: &[&PathBuf],
) -> Result<HashMap<PathBuf, Vec<(u32, u32)>>, ScopeError> {
    if files.is_empty() {
        return Ok(HashMap::new());
    }
    let mut argv: Vec<OsString> = [
        "diff",
        "-U0",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    argv.extend(args.iter().map(OsString::from));
    argv.push("--".into());
    for f in files {
        let rel = f.strip_prefix(top).unwrap_or(f);
        let mut spec = OsString::from(":(literal)");
        spec.push(rel.as_os_str());
        argv.push(spec);
    }
    Ok(parse_hunks(top, &git(top, &argv)?))
}

/// The added lines of each file of LIST, for KIND's `±`. A new file counts whole; a file whose diff has no added
/// line (deleted lines only) keeps nothing.
pub fn added_lines(
    list: &FileList,
    kind: ScopeKind,
) -> Result<HashMap<PathBuf, Added>, ScopeError> {
    let mut out: HashMap<PathBuf, Added> = HashMap::new();
    let old: Vec<&PathBuf> = list
        .files
        .iter()
        .filter(|f| !list.new.contains(*f))
        .collect();
    for f in list.files.iter().filter(|f| list.new.contains(*f)) {
        out.insert(
            f.clone(),
            Added {
                whole: true,
                ..Added::default()
            },
        );
    }
    let mut take = |map: HashMap<PathBuf, Vec<(u32, u32)>>, fell_back: bool| {
        for (f, ranges) in map {
            out.insert(
                f,
                Added {
                    ranges,
                    whole: false,
                    fell_back,
                },
            );
        }
    };
    match (kind, &list.against) {
        (ScopeKind::Staged, _) => {
            let (back, staged): (Vec<&PathBuf>, Vec<&PathBuf>) =
                old.iter().partition(|f| list.unstaged.contains(**f));
            take(hunks(&list.top, &["--cached"], &staged)?, false);
            take(hunks(&list.top, &["HEAD"], &back)?, true);
        }
        (_, Some(rev)) => take(hunks(&list.top, &[rev.as_str()], &old)?, false),
        (_, None) => {}
    }
    Ok(out)
}

/// The Branch scope's menu for DIR's repository.
pub fn bases(dir: &Path) -> Result<ScopeBases, ScopeError> {
    let top = toplevel(dir)?;
    let current = git_line(&top, &["symbolic-ref", "-q", "--short", "HEAD"]);
    let refs = git(
        &top,
        &[
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname)",
            "refs/heads",
            "refs/remotes",
        ],
    )?;
    let recent = String::from_utf8_lossy(&refs)
        .lines()
        .filter(|r| !(r.starts_with("refs/remotes/") && r.ends_with("/HEAD")))
        .filter_map(|r| {
            r.strip_prefix("refs/heads/")
                .or_else(|| r.strip_prefix("refs/remotes/"))
        })
        .filter(|r| Some(*r) != current.as_deref())
        .take(RECENT_BASES)
        .map(str::to_owned)
        .collect();
    Ok(ScopeBases {
        detached: current.is_none(),
        upstream: current.as_ref().and_then(|_| upstream(&top)),
        default: default_base(&top).ok(),
        current,
        recent,
    })
}

#[cfg(test)]
mod tests;
