//! The 3-way check a revert is compared with: `git merge-file -p` over three temporary files in a private folder (no
//! repository, so no tree is touched and no repository config is read).

use crate::{Error, Result};
use std::process::{Command, Stdio};

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
