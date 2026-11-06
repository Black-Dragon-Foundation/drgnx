//! What a runner returns is checked before it touches your tree (docs/guide/runners.md, "What comes back"; design
//! §6.3). Pure, but for [`write`], which writes beneath a job's folder through `eitri` and never follows a link.
//!
//! - [`path_ok`]: a returned path is relative and normalised, with no `..`, no absolute name and no NUL.
//! - [`never_returned`]: a cargo `target/`, a build tree or an image never comes back, whatever the job declared.
//! - [`archive_ok`]: a returned tar holds regular files and folders only (no link, device or FIFO).
//! - [`Patch`] and [`patch_ok`]: a `changes.patch` is applied only when every condition holds; otherwise it is kept
//!   with the card [`review_card`].
//! - [`counts_for_gates`] and [`shared_label`]: what a `shared` runner returns never counts for a gate or `needs`, and
//!   reaches an agent's wake labelled.

use eitri::{FsError, Kind};
use forseti::{JobSpec, RunnerTrust};
use rustix::fs::Mode;
use rustix::io::Errno;
use sleipnir::proto::JobRef;
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fmt;
use std::os::fd::BorrowedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// The hub's copy of a job's live log; beyond it the copy is cut in the middle and the whole stays on the runner.
pub const LOG_MAX: u64 = 64 << 20;
/// A job's test reports.
pub const REPORTS_MAX: u64 = 16 << 20;
/// A job's declared outputs; larger ones stay in the runner's artifact store.
pub const OUTPUTS_MAX: u64 = 256 << 20;
/// A job's `changes.patch`.
pub const PATCH_MAX: u64 = 16 << 20;

/// Why something a runner returned was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal(pub String);

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refusal {}

/// Names that make a build tree (a folder or a file of one), never returned.
const BUILD_TREES: [&str; 6] = [
    "CMakeFiles",
    "CMakeCache.txt",
    "build.ninja",
    ".ninja_log",
    ".ninja_deps",
    "config.status",
];
/// The extensions of container and machine images, never returned.
const IMAGES: [&str; 6] = ["oci", "qcow2", "vmdk", "vdi", "iso", "img"];

/// REL, relative and normalised (`.` and empty segments dropped), or why not.
pub fn path_ok(rel: &[u8]) -> Result<PathBuf, Refusal> {
    let shown = String::from_utf8_lossy(rel);
    if rel.contains(&0) {
        return Err(Refusal(format!("{shown:?}: a NUL byte in the path")));
    }
    if rel.first() == Some(&b'/') {
        return Err(Refusal(format!("{shown}: an absolute name")));
    }
    let mut out = PathBuf::new();
    for seg in rel.split(|b| *b == b'/') {
        match seg {
            b"" | b"." => {}
            b".." => return Err(Refusal(format!("{shown}: a `..` in the path"))),
            s => out.push(OsStr::from_bytes(s)),
        }
    }
    if out.as_os_str().is_empty() {
        return Err(Refusal(format!("{shown:?}: names no file")));
    }
    Ok(out)
}

/// What REL is if it may never come back (a cargo target, a build tree, an image), by its name alone.
pub fn never_returned(rel: &Path) -> Option<&'static str> {
    for c in rel.components() {
        let c = c.as_os_str();
        if c == "target" {
            return Some("a cargo target folder");
        }
        if BUILD_TREES.iter().any(|b| c == *b) {
            return Some("a build tree");
        }
        if c == "oci-layout" {
            return Some("an image");
        }
    }
    match rel.extension().and_then(OsStr::to_str) {
        Some(e) if IMAGES.contains(&e) => Some("an image"),
        _ => None,
    }
}

/// Writes BYTES to REL beneath the job's folder JOB_DIR (mode 0644, folders on the way 0755), never through a link;
/// the path written, or why not.
pub fn write(job_dir: BorrowedFd<'_>, rel: &[u8], bytes: &[u8]) -> Result<PathBuf, Refusal> {
    let path = path_ok(rel)?;
    if let Some(what) = never_returned(&path) {
        return Err(Refusal(format!(
            "{}: {what}, never returned",
            path.display()
        )));
    }
    let fail = |e: FsError| Refusal(format!("{}: {e}", path.display()));
    // the folders on the way, each opened beneath the job's folder (a link is refused, never followed) or made in the
    // one before it
    let mut at = PathBuf::new();
    for c in path.parent().into_iter().flat_map(Path::components) {
        let next = at.join(c);
        match eitri::open_beneath(job_dir, &next, Kind::Dir) {
            Ok(_) => {}
            Err(FsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                let mode = Mode::from_raw_mode(0o755);
                let made = if at.as_os_str().is_empty() {
                    rustix::fs::mkdirat(job_dir, c.as_os_str(), mode)
                } else {
                    let parent = eitri::open_beneath(job_dir, &at, Kind::Dir).map_err(fail)?;
                    rustix::fs::mkdirat(&parent.fd, c.as_os_str(), mode)
                };
                match made {
                    Ok(()) | Err(Errno::EXIST) => {}
                    Err(e) => return Err(fail(e.into())),
                }
                eitri::open_beneath(job_dir, &next, Kind::Dir).map_err(fail)?;
            }
            Err(e) => return Err(fail(e)),
        }
        at = next;
    }
    eitri::write_regular(job_dir, &path, bytes, 0o644).map_err(fail)?;
    Ok(path)
}

/// A header field's octal number (NUL or space ended; empty is 0), or none.
fn octal(field: &[u8]) -> Option<u64> {
    let digits = field
        .split(|b| *b == 0)
        .next()
        .unwrap_or_default()
        .trim_ascii();
    digits.iter().try_fold(0u64, |n, b| {
        (b'0'..=b'7')
            .contains(b)
            .then(|| n.checked_mul(8)?.checked_add(u64::from(b - b'0')))
            .flatten()
    })
}

/// A header field up to its first NUL.
fn cstr(field: &[u8]) -> &[u8] {
    field.split(|b| *b == 0).next().unwrap_or_default()
}

/// The name a ustar header gives (its prefix, then its name; a GNU header has no prefix).
fn header_name(h: &[u8]) -> Vec<u8> {
    let name = cstr(&h[..100]);
    let prefix = if &h[257..263] == b"ustar\0" {
        cstr(&h[345..500])
    } else {
        b""
    };
    if prefix.is_empty() {
        name.to_vec()
    } else {
        [prefix, b"/", name].concat()
    }
}

/// The value of KEY in the pax records BODY (`LEN KEY=VALUE\n`, LEN counting the whole record), or why they don't read.
fn pax_value<'a>(body: &'a [u8], key: &[u8]) -> Result<Option<&'a [u8]>, String> {
    let (mut rest, mut found) = (body, None);
    while !rest.is_empty() {
        let bad = || "a pax record that doesn't read".to_string();
        let sp = rest.iter().position(|b| *b == b' ').ok_or_else(bad)?;
        let len = std::str::from_utf8(&rest[..sp])
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|l| *l > sp + 1 && *l <= rest.len())
            .ok_or_else(bad)?;
        let rec = rest[sp + 1..len].strip_suffix(b"\n").ok_or_else(bad)?;
        let eq = rec.iter().position(|b| *b == b'=').ok_or_else(bad)?;
        if &rec[..eq] == key {
            found = Some(&rec[eq + 1..]);
        }
        rest = &rest[len..];
    }
    Ok(found)
}

/// The entries of the tar archive TAR if it holds only regular files and folders at paths that pass, or why not.
pub fn archive_ok(tar: &[u8]) -> Result<Vec<Entry>, Refusal> {
    let bad = |why: String| Refusal(format!("the archive: {why}"));
    let (mut out, mut at) = (Vec::new(), 0usize);
    let (mut long, mut pax): (Option<Vec<u8>>, Option<Vec<u8>>) = (None, None);
    loop {
        let h = tar
            .get(at..at + 512)
            .ok_or_else(|| bad("it ends inside a header, or has no end".into()))?;
        if h.iter().all(|b| *b == 0) {
            return Ok(out);
        }
        let sum: u64 = h
            .iter()
            .enumerate()
            .map(|(i, b)| {
                if (148..156).contains(&i) {
                    32
                } else {
                    u64::from(*b)
                }
            })
            .sum();
        if octal(&h[148..156]) != Some(sum) {
            return Err(bad(format!("the header at byte {at} has a wrong checksum")));
        }
        if &h[257..262] != b"ustar" {
            return Err(bad("not a ustar archive".into()));
        }
        let size = octal(&h[124..136]).ok_or_else(|| bad("a size that isn't octal".into()))?;
        let start = at + 512;
        let end = usize::try_from(size)
            .ok()
            .and_then(|s| start.checked_add(s))
            .filter(|e| *e <= tar.len())
            .ok_or_else(|| bad(format!("the entry at byte {at} is cut short")))?;
        let data = &tar[start..end];
        let typ = h[156];
        match typ {
            b'L' => long = Some(cstr(data).to_vec()),
            b'x' => {
                if let Some(p) = pax_value(data, b"path").map_err(bad)? {
                    pax = Some(p.to_vec());
                }
            }
            b'g' => {
                if pax_value(data, b"path").map_err(bad)?.is_some() {
                    return Err(bad("a global pax path".into()));
                }
            }
            0 | b'0' | b'7' | b'5' => {
                let raw = pax
                    .take()
                    .or_else(|| long.take())
                    .unwrap_or_else(|| header_name(h));
                let path = path_ok(&raw).map_err(|r| bad(r.0))?;
                if let Some(what) = never_returned(&path) {
                    return Err(bad(format!("{}: {what}, never returned", path.display())));
                }
                out.push(Entry {
                    path,
                    size,
                    dir: typ == b'5',
                });
            }
            t => {
                let raw = pax
                    .take()
                    .or_else(|| long.take())
                    .unwrap_or_else(|| header_name(h));
                let what = match t {
                    b'1' => "a hard link",
                    b'2' => "a symbolic link",
                    b'3' => "a character device",
                    b'4' => "a block device",
                    b'6' => "a FIFO",
                    _ => "an entry of a type it may not hold",
                };
                return Err(bad(format!("{}: {what}", String::from_utf8_lossy(&raw))));
            }
        }
        at = start + (end - start).div_ceil(512) * 512;
    }
}

/// An entry of a returned archive that passed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub path: PathBuf,
    pub size: u64,
    pub dir: bool,
}

/// One file a patch changes: its path before (none: created) and after (none: deleted), its modes, and the blob id
/// its `index` line gives the file before.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileChange {
    pub old: Option<Vec<u8>>,
    pub new: Option<Vec<u8>>,
    pub old_mode: Option<u32>,
    pub new_mode: Option<u32>,
    pub old_id: Option<String>,
}

/// A `changes.patch` (`git diff --full-index --binary` output) and the attempt it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Patch {
    pub from: JobRef,
    pub size: u64,
    pub files: Vec<FileChange>,
}

impl Patch {
    /// The files BYTES changes, or why it can't be read (it is then kept, never applied). A quoted path, a copy, a
    /// binary change without its data, text before the first `diff --git` and a header line it doesn't know can't be
    /// read: nothing is ever guessed.
    pub fn parse(from: JobRef, bytes: &[u8]) -> Result<Patch, Refusal> {
        let bad =
            |n: usize, why: &str| Refusal(format!("the patch can't be read: line {n}: {why}"));
        let mut files: Vec<FileChange> = Vec::new();
        // inside a file's header lines (before its first hunk or binary data)
        let mut header = false;
        for (i, line) in bytes.split(|b| *b == b'\n').enumerate() {
            let n = i + 1;
            if let Some(rest) = line.strip_prefix(b"diff --git ") {
                let (a, b) = git_paths(rest).ok_or_else(|| bad(n, "paths it can't read"))?;
                files.push(FileChange {
                    old: Some(a),
                    new: Some(b),
                    ..FileChange::default()
                });
                header = true;
                continue;
            }
            let Some(f) = files.last_mut() else {
                if line.is_empty() {
                    continue;
                }
                return Err(bad(n, "text before the first `diff --git`"));
            };
            if !header {
                continue;
            }
            let mode = |m: &[u8]| {
                octal(m)
                    .and_then(|m| u32::try_from(m).ok())
                    .ok_or_else(|| bad(n, "a mode"))
            };
            let path = |p: &[u8]| match p.first() {
                Some(b'"') => Err(bad(n, "a quoted path")),
                _ => Ok(p.strip_suffix(b"\t").unwrap_or(p).to_vec()),
            };
            if line.starts_with(b"@@") || line == b"GIT binary patch" {
                header = false;
            } else if let Some(m) = line.strip_prefix(b"old mode ") {
                f.old_mode = Some(mode(m)?);
            } else if let Some(m) = line.strip_prefix(b"new mode ") {
                f.new_mode = Some(mode(m)?);
            } else if let Some(m) = line.strip_prefix(b"deleted file mode ") {
                f.old_mode = Some(mode(m)?);
                f.new = None;
            } else if let Some(m) = line.strip_prefix(b"new file mode ") {
                f.new_mode = Some(mode(m)?);
                f.old = None;
            } else if let Some(ix) = line.strip_prefix(b"index ") {
                let mut words = ix.split(|b| *b == b' ');
                let ids = words.next().unwrap_or_default();
                let old = ids.split(|b| *b == b'.').next().unwrap_or_default();
                if !old.iter().all(u8::is_ascii_hexdigit) || old.is_empty() {
                    return Err(bad(n, "an index line"));
                }
                if old.iter().any(|b| *b != b'0') {
                    f.old_id = Some(String::from_utf8_lossy(old).into_owned());
                }
                if let Some(m) = words.next() {
                    let m = mode(m)?;
                    f.old_mode.get_or_insert(m);
                    f.new_mode.get_or_insert(m);
                }
            } else if line.starts_with(b"similarity index ")
                || line.starts_with(b"dissimilarity index ")
            {
            } else if let Some(p) = line.strip_prefix(b"rename from ") {
                f.old = Some(path(p)?);
            } else if let Some(p) = line.strip_prefix(b"rename to ") {
                f.new = Some(path(p)?);
            } else if let Some(p) = line.strip_prefix(b"--- ") {
                f.old = side(&path(p)?, b"a/").ok_or_else(|| bad(n, "a `---` line"))?;
            } else if let Some(p) = line.strip_prefix(b"+++ ") {
                f.new = side(&path(p)?, b"b/").ok_or_else(|| bad(n, "a `+++` line"))?;
            } else if line.starts_with(b"Binary files ") {
                return Err(bad(n, "a binary change without its data"));
            } else if line.starts_with(b"copy from ") || line.starts_with(b"copy to ") {
                return Err(bad(n, "a copy"));
            } else if !line.is_empty() {
                return Err(bad(n, "a header line it doesn't know"));
            }
        }
        Ok(Patch {
            from,
            size: bytes.len() as u64,
            files,
        })
    }
}

/// The two paths of a `diff --git a/X b/Y` line: the split where both halves are equal, or the only one there is.
fn git_paths(rest: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let rest = rest.strip_prefix(b"a/")?;
    let splits: Vec<usize> = (0..rest.len())
        .filter(|&i| rest[i..].starts_with(b" b/"))
        .collect();
    let at = splits
        .iter()
        .copied()
        .find(|&i| rest[..i] == rest[i + 3..])
        .or(match splits.as_slice() {
            [one] => Some(*one),
            _ => None,
        })?;
    Some((rest[..at].to_vec(), rest[at + 3..].to_vec()))
}

/// A `---`/`+++` line's path: none for `/dev/null`, the path without PREFIX, or no answer for anything else.
fn side(p: &[u8], prefix: &[u8]) -> Option<Option<Vec<u8>>> {
    if p == b"/dev/null" {
        return Some(None);
    }
    p.strip_prefix(prefix).map(|p| Some(p.to_vec()))
}

/// The protected name REL holds at any depth (one of the lock's [`NEVER_RESTORED`], which a revert never writes either,
/// or `.git`): a patch that touches one is never applied.
///
/// [`NEVER_RESTORED`]: crate::agents::lock::NEVER_RESTORED
pub(crate) fn protected(rel: &Path) -> Option<String> {
    use crate::agents::lock::NEVER_RESTORED;
    rel.components()
        .map(|c| c.as_os_str())
        .find(|c| *c == ".git" || NEVER_RESTORED.iter().any(|p| c == p))
        .map(|c| c.to_string_lossy().into_owned())
}

/// Whether PATH matches the `writes` glob PATTERN: `*` and `?` within one name, `**` as a whole segment any number of
/// folders, a trailing `/` the folder and all in it.
pub(crate) fn glob_ok(pattern: &str, path: &str) -> bool {
    let whole;
    let pattern = match pattern.strip_suffix('/') {
        Some(dir) => {
            whole = format!("{dir}/**");
            whole.as_str()
        }
        None => pattern,
    };
    let p: Vec<&str> = pattern
        .split('/')
        .filter(|s| !s.is_empty() && *s != ".")
        .collect();
    let s: Vec<&str> = path.split('/').collect();
    segments(&p, &s)
}

fn segments(p: &[&str], s: &[&str]) -> bool {
    match p.split_first() {
        None => s.is_empty(),
        Some((&"**", rest)) => (0..=s.len()).any(|i| segments(rest, &s[i..])),
        Some((first, rest)) => s
            .split_first()
            .is_some_and(|(h, t)| segment(first.as_bytes(), h.as_bytes()) && segments(rest, t)),
    }
}

/// One name against one pattern segment (`*` any run, `?` one byte), with one point to come back to.
fn segment(p: &[u8], s: &[u8]) -> bool {
    let (mut pi, mut si) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while si < s.len() {
        if pi < p.len() && (p[pi] == b'?' || p[pi] == s[si]) {
            pi += 1;
            si += 1;
        } else if pi < p.len() && p[pi] == b'*' {
            star = Some((pi, si));
            pi += 1;
        } else if let Some((sp, ss)) = star {
            pi = sp + 1;
            si = ss + 1;
            star = Some((sp, ss + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|b| *b == b'*')
}

/// Whether PATCH may be applied to the caller's tree: every path is one of JOB's `writes` globs, none is protected,
/// under `.git`, a link, a submodule or outside the tree, no executable bit changes, each file is at its SUBMIT hash
/// (path → blob id at submit; a created file has none), it comes from the job's current ATTEMPT (its number and
/// nonce), and not from a `shared` RUNNER. Every reason it may not, or none.
pub fn patch_ok(
    patch: &Patch,
    job: &JobSpec,
    attempt: &JobRef,
    submit: &BTreeMap<PathBuf, String>,
    runner: RunnerTrust,
) -> Result<(), Vec<String>> {
    let mut why = Vec::new();
    if runner == RunnerTrust::Shared {
        why.push("it comes from a shared runner, whose changes are never applied".to_string());
    }
    let from = &patch.from;
    if from.job != attempt.job {
        why.push(format!(
            "it is job {}'s, not job {}'s",
            from.job, attempt.job
        ));
    } else if from.attempt != attempt.attempt {
        why.push(format!(
            "it comes from attempt {}, not the current attempt {}",
            from.attempt, attempt.attempt
        ));
    } else if from.nonce != attempt.nonce {
        why.push(format!("its nonce isn't attempt {}'s", attempt.attempt));
    }
    if patch.size > PATCH_MAX {
        why.push(format!("it is larger than {} MiB", PATCH_MAX >> 20));
    }
    for f in &patch.files {
        let mut paths: Vec<&[u8]> = [f.old.as_deref(), f.new.as_deref()]
            .into_iter()
            .flatten()
            .collect();
        paths.dedup();
        for p in paths {
            let shown = String::from_utf8_lossy(p);
            let path = match path_ok(p) {
                Ok(path) => path,
                Err(r) => {
                    why.push(r.0);
                    continue;
                }
            };
            if let Some(name) = protected(&path) {
                why.push(format!("{shown}: {name} is protected"));
            } else if !path
                .to_str()
                .is_some_and(|s| job.writes.iter().any(|g| glob_ok(g, s)))
            {
                why.push(format!("{shown} is outside the job's writes"));
            }
        }
        let name =
            String::from_utf8_lossy(f.new.as_deref().or(f.old.as_deref()).unwrap_or_default());
        let kinds: Vec<u32> = [f.old_mode, f.new_mode]
            .into_iter()
            .flatten()
            .map(|m| m & 0o170000)
            .collect();
        if kinds.contains(&0o120000) {
            why.push(format!("{name}: a symlink"));
        }
        if kinds.contains(&0o160000) {
            why.push(format!("{name}: a submodule"));
        }
        match (f.old.as_ref(), f.old_mode, f.new_mode) {
            (_, Some(a), Some(b)) if a != b => why.push(format!(
                "{name}: its executable bit changes ({a:o} to {b:o})"
            )),
            (None, _, Some(b)) if b & 0o170000 == 0o100000 && b & 0o111 != 0 => {
                why.push(format!("{name}: a new executable file"))
            }
            _ => {}
        }
        match (f.old.as_deref(), f.new.as_deref()) {
            (Some(old), _) => {
                let shown = String::from_utf8_lossy(old);
                let at_submit = path_ok(old).ok().and_then(|k| submit.get(&k));
                match (at_submit, &f.old_id) {
                    (None, _) => why.push(format!(
                        "{shown}: not among the files hashed when the job was submitted"
                    )),
                    (Some(_), None) => why.push(format!(
                        "{shown}: the patch names no blob for it (no full `index` line)"
                    )),
                    (Some(h), Some(id)) if h != id => {
                        why.push(format!("{shown}: changed since the job was submitted"))
                    }
                    _ => {}
                }
            }
            (None, Some(new)) => {
                if path_ok(new).ok().is_some_and(|k| submit.contains_key(&k)) {
                    why.push(format!(
                        "{}: there at submit, and the patch creates it",
                        String::from_utf8_lossy(new)
                    ));
                }
            }
            (None, None) => {}
        }
    }
    if why.is_empty() { Ok(()) } else { Err(why) }
}

/// The card a patch that is kept, not applied, shows.
pub fn review_card(runner: &str, files: usize) -> String {
    if files == 1 {
        format!("{runner} returned changes to 1 file; review it")
    } else {
        format!("{runner} returned changes to {files} files; review them")
    }
}

/// Whether a result from a runner of this trust may count for a gate or a job's `needs`, or be promoted.
pub fn counts_for_gates(runner: RunnerTrust) -> bool {
    runner != RunnerTrust::Shared
}

/// The line a summary from the `shared` runner RUNNER starts with, so a woken agent reads it as untrusted.
pub fn shared_label(runner: &str) -> String {
    format!("output from runner {runner} (shared)")
}

#[cfg(test)]
mod tests {
    use super::*;
    use sleipnir::proto::Nonce;
    use std::fs;
    use std::os::fd::{AsFd, OwnedFd};
    use std::os::unix::fs::symlink;

    fn refused(r: Result<PathBuf, Refusal>) -> bool {
        r.is_err()
    }

    /// [D]a returned path is relative and normalised; `..`, an absolute name and a NUL are refused.
    #[test]
    fn dotdot_absolute_and_nul_paths_are_refused() {
        for bad in [
            &b"../x"[..],
            b"a/../../x",
            b"a/..",
            b"..",
            b"/etc/passwd",
            b"//x",
            b"a\0b",
            b"",
            b".",
            b"./",
        ] {
            assert!(refused(path_ok(bad)), "{:?}", String::from_utf8_lossy(bad));
        }
        assert_eq!(path_ok(b"a/./b//c/").unwrap(), PathBuf::from("a/b/c"));
        assert_eq!(
            path_ok(b"reports/junit.xml").unwrap(),
            PathBuf::from("reports/junit.xml")
        );
        assert_eq!(path_ok(b"a..b/..c").unwrap(), PathBuf::from("a..b/..c"));
    }

    /// One ustar entry: NAME (with PREFIX), TYPE, DATA and LINK.
    fn entry(prefix: &str, name: &str, typ: u8, data: &[u8], link: &str) -> Vec<u8> {
        let mut h = [0u8; 512];
        h[..name.len()].copy_from_slice(name.as_bytes());
        h[100..108].copy_from_slice(b"0000644\0");
        h[108..116].copy_from_slice(b"0000000\0");
        h[116..124].copy_from_slice(b"0000000\0");
        h[124..136].copy_from_slice(format!("{:011o}\0", data.len()).as_bytes());
        h[136..148].copy_from_slice(b"00000000000\0");
        h[156] = typ;
        h[157..157 + link.len()].copy_from_slice(link.as_bytes());
        h[257..263].copy_from_slice(b"ustar\0");
        h[263..265].copy_from_slice(b"00");
        h[345..345 + prefix.len()].copy_from_slice(prefix.as_bytes());
        h[148..156].copy_from_slice(b"        ");
        let sum: u32 = h.iter().map(|b| u32::from(*b)).sum();
        h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
        let mut out = h.to_vec();
        out.extend_from_slice(data);
        out.resize(out.len().div_ceil(512) * 512, 0);
        out
    }

    fn file(name: &str, data: &[u8]) -> Vec<u8> {
        entry("", name, b'0', data, "")
    }

    fn tar(entries: &[Vec<u8>]) -> Vec<u8> {
        let mut out: Vec<u8> = entries.concat();
        out.extend_from_slice(&[0; 1024]);
        out
    }

    /// A pax extended header holding PATH for the next entry.
    fn pax_path(path: &str) -> Vec<u8> {
        let body = format!("path={path}\n");
        let mut len = body.len() + 3;
        if format!("{len} {body}").len() != len {
            len += 1;
        }
        entry(
            "",
            "././@PaxHeader",
            b'x',
            format!("{len} {body}").as_bytes(),
            "",
        )
    }

    /// [D]an archive holding a link (symbolic or hard), a device or a FIFO is refused; regular files and folders
    /// pass, a ustar prefix, a GNU long name and a pax path included, each name checked as a returned path.
    #[test]
    fn a_link_in_an_archive_is_refused() {
        let good = tar(&[
            entry("", "reports/", b'5', b"", ""),
            file("reports/junit.xml", b"<testsuite/>"),
            entry("deep/er", "x.txt", b'0', b"x", ""),
            entry("", "././@LongLink", b'L', b"long/name/for/a/file.txt\0", ""),
            file("long/name/for/a/fi", b"lng"),
            pax_path("pax/named.txt"),
            file("ignored-name", b"pax"),
        ]);
        let got = archive_ok(&good).unwrap();
        let names: Vec<(String, u64, bool)> = got
            .iter()
            .map(|e| (e.path.display().to_string(), e.size, e.dir))
            .collect();
        assert_eq!(
            names,
            [
                ("reports".to_string(), 0, true),
                ("reports/junit.xml".to_string(), 12, false),
                ("deep/er/x.txt".to_string(), 1, false),
                ("long/name/for/a/file.txt".to_string(), 3, false),
                ("pax/named.txt".to_string(), 3, false),
            ]
        );
        for (what, bad) in [
            ("a symlink", entry("", "out", b'2', b"", "/etc/passwd")),
            (
                "a hard link",
                entry("", "out", b'1', b"", "reports/junit.xml"),
            ),
            ("a char device", entry("", "tty", b'3', b"", "")),
            ("a block device", entry("", "disk", b'4', b"", "")),
            ("a FIFO", entry("", "pipe", b'6', b"", "")),
            ("an unknown type", entry("", "sparse", b'S', b"", "")),
            ("a .. name", file("../escape", b"x")),
            ("an absolute name", file("/etc/cron.d/x", b"x")),
            (
                "a pax .. name",
                [pax_path("a/../../x"), file("ok", b"x")].concat(),
            ),
        ] {
            let r = archive_ok(&tar(&[file("reports/ok.txt", b"ok"), bad]));
            assert!(r.is_err(), "{what}: {r:?}");
        }
        // a broken checksum, a truncated entry and no end are refused too
        let mut sum = tar(&[file("a", b"x")]);
        sum[148] = b'7';
        assert!(archive_ok(&sum).is_err());
        let whole = tar(&[file("a", &[7; 600])]);
        assert!(archive_ok(&whole[..700]).is_err());
        assert!(archive_ok(&whole[..1536]).is_err());
    }

    fn job_dir() -> (tempfile::TempDir, OwnedFd) {
        let d = tempfile::tempdir().unwrap();
        let fd = fs::File::open(d.path()).unwrap().into();
        (d, fd)
    }

    /// [D]a link planted in the job's folder is never followed: a write through a linked folder fails and makes
    /// nothing behind it, a linked file is replaced, never written through; the sentinel outside is untouched.
    #[test]
    fn a_planted_symlink_in_the_job_dir_is_not_followed() {
        let (d, fd) = job_dir();
        let outside = tempfile::tempdir().unwrap();
        let sentinel = outside.path().join("sentinel");
        fs::write(&sentinel, "keep").unwrap();
        symlink(outside.path(), d.path().join("reports")).unwrap();
        symlink(&sentinel, d.path().join("out.txt")).unwrap();

        let r = write(fd.as_fd(), b"reports/junit.xml", b"<testsuite/>");
        assert!(r.is_err(), "{r:?}");
        assert!(!outside.path().join("junit.xml").exists());
        let r = write(fd.as_fd(), b"reports/new/deeper.txt", b"x");
        assert!(r.is_err(), "{r:?}");
        assert!(!outside.path().join("new").exists());

        assert_eq!(
            write(fd.as_fd(), b"out.txt", b"returned").unwrap(),
            PathBuf::from("out.txt")
        );
        assert!(
            fs::symlink_metadata(d.path().join("out.txt"))
                .unwrap()
                .is_file()
        );
        assert_eq!(fs::read_to_string(&sentinel).unwrap(), "keep");
        // a nested path gets its folders, beneath the job's folder only
        assert_eq!(
            write(fd.as_fd(), b"a/b/c.txt", b"c").unwrap(),
            PathBuf::from("a/b/c.txt")
        );
        assert_eq!(fs::read(d.path().join("a/b/c.txt")).unwrap(), b"c");
        assert!(write(fd.as_fd(), b"../escape.txt", b"x").is_err());
        assert!(!d.path().parent().unwrap().join("escape.txt").exists());
    }

    fn nonce(b: u8) -> Nonce {
        Nonce([b; 16])
    }

    fn jref(attempt: u32, n: u8) -> JobRef {
        JobRef {
            job: "xj".into(),
            attempt,
            nonce: nonce(n),
        }
    }

    const OLD: &str = "1111111111111111111111111111111111111111";
    const NEW: &str = "2222222222222222222222222222222222222222";
    const NONE: &str = "0000000000000000000000000000000000000000";

    /// A patch that changes the text of PATH (mode 100644), whose blob before is OLD.
    fn modify(path: &str) -> String {
        format!(
            "diff --git a/{path} b/{path}\nindex {OLD}..{NEW} 100644\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n-old\n+new\n"
        )
    }

    fn spec(writes: &[&str]) -> JobSpec {
        let mut s = super::super::queue::blank_spec("fmt");
        s.writes = writes.iter().map(|w| w.to_string()).collect();
        s
    }

    fn submit(paths: &[&str]) -> BTreeMap<PathBuf, String> {
        paths
            .iter()
            .map(|p| (PathBuf::from(p), OLD.to_string()))
            .collect()
    }

    /// The reasons PATCH (from attempt 2, nonce 2, of a runner of yours) is refused for a job writing WRITES whose
    /// SUBMITTED files were hashed; none: it may be applied.
    fn reasons(patch: &str, writes: &[&str], submitted: &[&str]) -> Vec<String> {
        let p = Patch::parse(jref(2, 2), patch.as_bytes()).unwrap();
        match patch_ok(
            &p,
            &spec(writes),
            &jref(2, 2),
            &submit(submitted),
            RunnerTrust::Mine,
        ) {
            Ok(()) => vec![],
            Err(r) => r,
        }
    }

    fn mentions(rs: &[String], what: &str) -> bool {
        rs.iter().any(|r| r.contains(what))
    }

    /// [D]a patch that touches `build.rs` when the job declared only its golden files and `Cargo.lock` is not
    /// applied, and names the file; one within the globs is.
    #[test]
    fn a_patch_touching_build_rs_outside_writes_is_not_applied() {
        let writes = ["Cargo.lock", "tests/golden/**", "docs/*.md"];
        let ok = format!(
            "{}{}{}",
            modify("Cargo.lock"),
            modify("tests/golden/a/b.txt"),
            modify("docs/x.md")
        );
        let p = Patch::parse(jref(2, 2), ok.as_bytes()).unwrap();
        assert_eq!(p.files.len(), 3);
        assert_eq!(p.files[0].old.as_deref(), Some(&b"Cargo.lock"[..]));
        assert_eq!(p.files[0].old_id.as_deref(), Some(OLD));
        assert_eq!(p.files[0].new_mode, Some(0o100644));
        assert_eq!(
            reasons(
                &ok,
                &writes,
                &["Cargo.lock", "tests/golden/a/b.txt", "docs/x.md"]
            ),
            Vec::<String>::new()
        );
        let bad = format!("{}{}", modify("Cargo.lock"), modify("build.rs"));
        let rs = reasons(&bad, &writes, &["Cargo.lock", "build.rs"]);
        assert!(mentions(&rs, "build.rs"), "{rs:?}");
        assert!(!mentions(&rs, "Cargo.lock"), "{rs:?}");
        // `*` stays in its folder: docs/sub/x.md isn't docs/*.md
        let rs = reasons(&modify("docs/sub/x.md"), &writes, &["docs/sub/x.md"]);
        assert!(mentions(&rs, "docs/sub/x.md"), "{rs:?}");
        // a job that declared no writes has every change refused
        assert!(!reasons(&modify("Cargo.lock"), &[], &["Cargo.lock"]).is_empty());
    }

    /// [D]a patch touching a protected file (`.envrc`, `.claude`, `mise.toml`, …) or anything under `.git`, at any
    /// depth, is not applied, even when the job's writes are `**`; nor is one leaving the tree, or a file that changed
    /// since the job was submitted.
    #[test]
    fn a_patch_touching_envrc_or_dot_git_is_not_applied() {
        for path in [
            ".envrc",
            "sub/.envrc",
            ".claude/settings.json",
            ".codex/config.toml",
            ".gemini/x",
            "mise.toml",
            ".git/hooks/pre-commit",
            ".git/config",
            "vendor/dep/.git/config",
        ] {
            let rs = reasons(&modify(path), &["**"], &[path]);
            assert!(mentions(&rs, path), "{path}: {rs:?}");
        }
        let rs = reasons(&modify("../outside.txt"), &["**"], &["../outside.txt"]);
        assert!(!rs.is_empty());
        // a renamed file is checked at both names
        let rename = "diff --git a/notes.txt b/.envrc\nsimilarity index 100%\nrename from notes.txt\nrename to .envrc\n";
        let rs = reasons(rename, &["**"], &["notes.txt"]);
        assert!(mentions(&rs, ".envrc"), "{rs:?}");
        // the file changed since submit (its blob differs), or wasn't hashed at all
        let mut changed = submit(&["Cargo.lock"]);
        changed.insert(PathBuf::from("Cargo.lock"), NEW.into());
        let p = Patch::parse(jref(2, 2), modify("Cargo.lock").as_bytes()).unwrap();
        let r = patch_ok(&p, &spec(&["**"]), &jref(2, 2), &changed, RunnerTrust::Mine);
        assert!(r.is_err_and(|rs| mentions(&rs, "Cargo.lock")));
        assert!(!reasons(&modify("Cargo.lock"), &["**"], &[]).is_empty());
        // a quoted (unusual) path is never read as another one: the patch can't be read, so it is kept
        let quoted = "diff --git \"a/x\\n\" \"b/x\\n\"\nindex 1..2 100644\n";
        assert!(Patch::parse(jref(2, 2), quoted.as_bytes()).is_err());
    }

    /// [D]no executable bit changes: a mode change, a new executable file, and a new symlink or submodule are
    /// all refused.
    #[test]
    fn an_exec_bit_change_is_not_applied() {
        let mode = "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n";
        let rs = reasons(mode, &["**"], &["run.sh"]);
        assert!(
            mentions(&rs, "run.sh") && mentions(&rs, "executable"),
            "{rs:?}"
        );
        let new_exec = format!(
            "diff --git a/tool.sh b/tool.sh\nnew file mode 100755\nindex {NONE}..{NEW}\n--- /dev/null\n+++ b/tool.sh\n@@ -0,0 +1 @@\n+echo\n"
        );
        let rs = reasons(&new_exec, &["**"], &[]);
        assert!(
            mentions(&rs, "tool.sh") && mentions(&rs, "executable"),
            "{rs:?}"
        );
        let link = format!(
            "diff --git a/link b/link\nnew file mode 120000\nindex {NONE}..{NEW}\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/etc/passwd\n\\ No newline at end of file\n"
        );
        let rs = reasons(&link, &["**"], &[]);
        assert!(mentions(&rs, "link") && mentions(&rs, "symlink"), "{rs:?}");
        let sub = format!(
            "diff --git a/dep b/dep\nnew file mode 160000\nindex {NONE}..{NEW}\n--- /dev/null\n+++ b/dep\n@@ -0,0 +1 @@\n+Subproject commit {NEW}\n"
        );
        let rs = reasons(&sub, &["**"], &[]);
        assert!(mentions(&rs, "submodule"), "{rs:?}");
        // a plain new file, and a deleted one, pass
        let plain = format!(
            "diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex {NONE}..{NEW}\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+x\n"
        );
        assert_eq!(reasons(&plain, &["**"], &[]), Vec::<String>::new());
        let gone = format!(
            "diff --git a/old.txt b/old.txt\ndeleted file mode 100644\nindex {OLD}..{NONE}\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n"
        );
        let p = Patch::parse(jref(2, 2), gone.as_bytes()).unwrap();
        assert_eq!(
            (p.files[0].old.as_deref(), p.files[0].new.as_deref()),
            (Some(&b"old.txt"[..]), None)
        );
        assert_eq!(reasons(&gone, &["**"], &["old.txt"]), Vec::<String>::new());
    }

    /// [D]a patch from an attempt other than the job's current one (an older number, or the right number with
    /// another nonce) is kept, not applied, and its card says to review it.
    #[test]
    fn a_patch_from_an_old_attempt_is_kept_not_applied() {
        let text = modify("Cargo.lock");
        let check = |from: JobRef| {
            let p = Patch::parse(from, text.as_bytes()).unwrap();
            patch_ok(
                &p,
                &spec(&["Cargo.lock"]),
                &jref(2, 2),
                &submit(&["Cargo.lock"]),
                RunnerTrust::Mine,
            )
        };
        assert_eq!(check(jref(2, 2)), Ok(()));
        let old = check(jref(1, 1)).unwrap_err();
        assert!(mentions(&old, "attempt 1"), "{old:?}");
        let forged = check(jref(2, 9)).unwrap_err();
        assert!(mentions(&forged, "nonce"), "{forged:?}");
        let other = check(JobRef {
            job: "xother".into(),
            ..jref(2, 2)
        })
        .unwrap_err();
        assert!(mentions(&other, "xother"), "{other:?}");
        assert_eq!(
            review_card("desktop", 3),
            "desktop returned changes to 3 files; review them"
        );
        assert_eq!(
            review_card("desktop", 1),
            "desktop returned changes to 1 file; review it"
        );
    }

    /// [D]a patch from a `shared` runner is never applied, however clean; from `mine` or `my-cloud` it is. A
    /// shared runner's results never count for a gate, and its summaries are labelled.
    #[test]
    fn a_patch_from_shared_is_never_applied() {
        let p = Patch::parse(jref(2, 2), modify("Cargo.lock").as_bytes()).unwrap();
        let check = |t| {
            patch_ok(
                &p,
                &spec(&["Cargo.lock"]),
                &jref(2, 2),
                &submit(&["Cargo.lock"]),
                t,
            )
        };
        assert_eq!(check(RunnerTrust::Mine), Ok(()));
        assert_eq!(check(RunnerTrust::MyCloud), Ok(()));
        let rs = check(RunnerTrust::Shared).unwrap_err();
        assert!(mentions(&rs, "shared"), "{rs:?}");
        assert!(counts_for_gates(RunnerTrust::Mine) && counts_for_gates(RunnerTrust::MyCloud));
        assert!(!counts_for_gates(RunnerTrust::Shared));
        assert_eq!(
            shared_label("uni-box"),
            "output from runner uni-box (shared)"
        );
        // a patch over the limit is refused whoever sent it
        let mut big = p.clone();
        big.size = PATCH_MAX + 1;
        let r = patch_ok(
            &big,
            &spec(&["Cargo.lock"]),
            &jref(2, 2),
            &submit(&["Cargo.lock"]),
            RunnerTrust::Mine,
        );
        assert!(r.is_err_and(|rs| mentions(&rs, "16 MiB")));
    }

    /// [D]a cargo `target/` (at any depth), a build tree or an image never comes back, by name, whatever the job
    /// declared: not written, and an archive holding one is refused.
    #[test]
    fn target_is_never_returned() {
        for p in [
            "target/debug/drgnx",
            "runtime/target/release/x",
            "build/CMakeFiles/x.o",
            "CMakeCache.txt",
            "out/build.ninja",
            "image/oci-layout",
            "dist/image.oci",
            "vm/disk.qcow2",
        ] {
            assert!(never_returned(Path::new(p)).is_some(), "{p}");
        }
        for p in [
            "reports/junit.xml",
            "targets.txt",
            "docs/target-audience.md",
        ] {
            assert_eq!(never_returned(Path::new(p)), None, "{p}");
        }
        let (d, fd) = job_dir();
        assert!(write(fd.as_fd(), b"target/debug/drgnx", b"elf").is_err());
        assert!(!d.path().join("target").exists());
        let r = archive_ok(&tar(&[
            file("reports/ok.txt", b"ok"),
            file("runtime/target/debug/x", b"elf"),
        ]));
        assert!(r.is_err(), "{r:?}");
        assert!(archive_ok(&tar(&[file("oci-layout", b"{}")])).is_err());
    }
}
