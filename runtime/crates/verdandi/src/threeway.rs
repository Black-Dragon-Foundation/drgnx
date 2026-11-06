//! The 3-way check a revert is compared with: `git merge-file -p` over three temporary files in a private folder (no
//! repository, so no tree is touched and no repository config is read).

use crate::{Error, Result};
use std::process::{Command, Stdio};

/// The hunks `git diff --no-index --unified=0` gives for OLD to NEW (git's numbers): (old start, old count, new start,
/// new count).
pub(crate) fn diff_hunks(old: &str, new: &str) -> Result<Vec<(usize, usize, usize, usize)>> {
    let dir = tempfile::Builder::new().prefix("verdandi-diff").tempdir()?;
    for (name, text) in [("old", old), ("new", new)] {
        std::fs::write(dir.path().join(name), text)?;
    }
    let out = Command::new("git")
        .args([
            "diff",
            "--no-index",
            "--no-color",
            "--unified=0",
            "old",
            "new",
        ])
        .current_dir(dir.path())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env_remove("GIT_DIR")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    // 0: no difference, 1: a difference
    if !matches!(out.status.code(), Some(0 | 1)) {
        return Err(Error::Refused("git diff failed".into()));
    }
    let bad = || Error::Refused("git diff gave a hunk header it could not read".into());
    let num = |s: &str| -> Option<(usize, usize)> {
        let s = s.trim_start_matches(['-', '+']);
        match s.split_once(',') {
            Some((a, b)) => Some((a.parse().ok()?, b.parse().ok()?)),
            None => Some((s.parse().ok()?, 1)),
        }
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut hunks = Vec::new();
    for l in text.lines().filter(|l| l.starts_with("@@ ")) {
        let mut w = l.split_whitespace().skip(1);
        let (o, n) = (
            w.next().and_then(num).ok_or_else(bad)?,
            w.next().and_then(num).ok_or_else(bad)?,
        );
        hunks.push((o.0, o.1, n.0, n.1));
    }
    Ok(hunks)
}

/// The 3-way merge of OURS and THEIRS from BASE: (clean, merged text).  A conflicted merge's text has git's markers.
pub(crate) fn merge(base: &str, ours: &str, theirs: &str) -> Result<(bool, String)> {
    let dir = tempfile::Builder::new().prefix("verdandi-3way").tempdir()?;
    for (name, text) in [("ours", ours), ("base", base), ("theirs", theirs)] {
        std::fs::write(dir.path().join(name), text)?;
    }
    let out = Command::new("git")
        .args(["merge-file", "-p", "ours", "base", "theirs"])
        .current_dir(dir.path())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env_remove("GIT_DIR")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    // the exit status is the number of conflicts (at most 127); above that, an error
    match out.status.code() {
        Some(n) if (0..=127).contains(&n) => Ok((
            n == 0,
            String::from_utf8(out.stdout)
                .map_err(|_| Error::Refused("git merge-file gave text that is not UTF-8".into()))?,
        )),
        _ => Err(Error::Refused("git merge-file failed".into())),
    }
}
