//! Git object ids for what the history records, always through a git directory the caller names (the run's trusted
//! store for a tree a sandboxed agent worked in, never plain git inside such a tree).  The bytes come from the caller
//! (read through `eitri`), never from a second read of the path.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

fn base(git_dir: &Path, work_tree: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("--git-dir")
        .arg(git_dir)
        .arg("--work-tree")
        .arg(work_tree)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C");
    c
}

fn run(mut c: Command, input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    c.stdin(if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = c.spawn().map_err(|e| e.to_string())?;
    if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
        // a broken pipe is git's own error, reported by its exit status
        let _ = stdin.write_all(bytes);
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

/// The blob id of BYTES as git would store the file REL of WORK_TREE: the repository's filters and object format
/// (`git hash-object --path`).
pub fn hash_object(
    git_dir: &Path,
    work_tree: &Path,
    rel: &str,
    bytes: &[u8],
) -> Result<String, String> {
    let mut c = base(git_dir, work_tree);
    c.args(["hash-object", "--stdin", "--path", rel]);
    Ok(String::from_utf8_lossy(&run(c, Some(bytes))?)
        .trim()
        .to_owned())
}

/// The blob id of BYTES with no filter (a link's target).
pub fn hash_raw(git_dir: &Path, work_tree: &Path, bytes: &[u8]) -> Result<String, String> {
    let mut c = base(git_dir, work_tree);
    c.args(["hash-object", "--stdin", "--no-filters"]);
    Ok(String::from_utf8_lossy(&run(c, Some(bytes))?)
        .trim()
        .to_owned())
}

/// REL's content at COMMIT, or none when it is not there.
pub fn text_at(git_dir: &Path, work_tree: &Path, commit: &str, rel: &str) -> Option<Vec<u8>> {
    let mut c = base(git_dir, work_tree);
    c.args(["cat-file", "blob", &format!("{commit}:{rel}")]);
    run(c, None).ok()
}

/// `git blame --porcelain` of REL, of CONTENTS when given (the text of an editor's buffer, read from stdin) in place
/// of the file's.  An error is git's own message.
pub fn blame_porcelain(
    git_dir: &Path,
    work_tree: &Path,
    rel: &str,
    contents: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    let mut c = base(git_dir, work_tree);
    c.args(["blame", "--porcelain"]);
    if contents.is_some() {
        c.args(["--contents", "-"]);
    }
    c.args(["--", rel]);
    run(c, contents)
}

/// REL's content in the index (stage 0), or none when the index does not hold it, with the file's mode.
pub fn index_entry(git_dir: &Path, work_tree: &Path, rel: &str) -> Option<(String, Vec<u8>)> {
    let mut c = base(git_dir, work_tree);
    c.args(["ls-files", "-s", "--", rel]);
    let line = String::from_utf8_lossy(&run(c, None).ok()?).into_owned();
    let (mode, rest) = line.split_once(' ')?;
    let sha = rest.split(' ').next()?;
    let mut c = base(git_dir, work_tree);
    c.args(["cat-file", "blob", sha]);
    Some((mode.to_owned(), run(c, None).ok()?))
}

/// Put BYTES in the index as REL with MODE (the blob is written to the object store first).
pub fn stage_bytes(
    git_dir: &Path,
    work_tree: &Path,
    rel: &str,
    mode: &str,
    bytes: &[u8],
) -> Result<(), String> {
    let mut c = base(git_dir, work_tree);
    c.args(["hash-object", "-w", "--stdin", "--path", rel]);
    let sha = String::from_utf8_lossy(&run(c, Some(bytes))?)
        .trim()
        .to_owned();
    let mut c = base(git_dir, work_tree);
    c.args([
        "update-index",
        "--add",
        "--cacheinfo",
        &format!("{mode},{sha},{rel}"),
    ]);
    run(c, None).map(|_| ())
}

/// The paths that differ between the commits OLD and NEW.
pub fn changed_paths(
    git_dir: &Path,
    work_tree: &Path,
    old: &str,
    new: &str,
) -> Result<Vec<String>, String> {
    let mut c = base(git_dir, work_tree);
    c.args([
        "diff-tree",
        "-r",
        "--name-only",
        "--no-renames",
        "-z",
        old,
        new,
    ]);
    let out = run(c, None)?;
    Ok(String::from_utf8_lossy(&out)
        .split('\0')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect())
}

/// The paths of the work tree that differ from its head: changed, deleted and untracked (not ignored) files.
pub fn dirty_paths(git_dir: &Path, work_tree: &Path) -> Result<Vec<String>, String> {
    let mut c = base(git_dir, work_tree);
    c.current_dir(work_tree).args([
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--no-renames",
    ]);
    let out = run(c, None)?;
    // `-z` with no renames: one "XY path" per record
    Ok(String::from_utf8_lossy(&out)
        .split('\0')
        .filter_map(|r| r.get(3..))
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect())
}

/// Whether git ignores REL (`.gitignore` and the like).
pub fn is_ignored(git_dir: &Path, work_tree: &Path, rel: &str) -> bool {
    let mut c = base(git_dir, work_tree);
    c.args(["check-ignore", "-q", "--no-index", "--", rel]);
    c.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    c.status().is_ok_and(|s| s.success())
}

/// Whether REL is generated code by `.gitattributes` (`linguist-generated`).
pub fn is_generated(git_dir: &Path, work_tree: &Path, rel: &str) -> bool {
    let mut c = base(git_dir, work_tree);
    c.args(["check-attr", "linguist-generated", "--", rel]);
    run(c, None).is_ok_and(|o| {
        let s = String::from_utf8_lossy(&o);
        let v = s.rsplit(": ").next().unwrap_or("").trim();
        v == "set" || v == "true"
    })
}
