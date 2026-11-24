//! The hardened git (docs/develop/sleipnir.md, "Sync"): `Git::cmd` is the only constructor for a git command in
//! sleipnir.
//!
//! On a runner, git never runs inside anything a job can write: the git dir is always given (`GIT_DIR`), so git
//! never discovers a `.git` a job planted, and the work tree is passed with `--work-tree`. Every command also gets:
//!
//! - `-c core.hooksPath=/dev/null -c core.fsmonitor=false`: no hook and no fsmonitor program ever runs;
//! - `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`: only the git dir's own config (ours) and these `-c`s;
//! - `-c transfer.fsckObjects=true`: every object received is checked;
//! - no inherited `GIT_*` variable (`GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_DIR`, …), and
//!   `GIT_TERMINAL_PROMPT=0`, so git never asks.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use super::{Result, SyncError};

/// The `-c` options every git command of sleipnir starts with.
pub const HARDENING: [&str; 6] = [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "transfer.fsckObjects=true",
];

/// A git dir and, unless it is bare, the work tree git acts on.
#[derive(Clone, Debug)]
pub struct Git {
    pub git_dir: PathBuf,
    pub work_tree: Option<PathBuf>,
}

impl Git {
    /// The user's own worktree at `top` (its top level), on the hub: the git dir is `top/.git`, or the one a `.git`
    /// file names (a linked worktree). Never used for a slot: a slot's `.git` is deleted, never read.
    pub fn for_worktree(top: &Path) -> io::Result<Git> {
        let dot = top.join(".git");
        let meta = fs::symlink_metadata(&dot)?;
        let git_dir = if meta.is_dir() {
            dot
        } else if meta.is_file() {
            let text = fs::read(&dot)?;
            let rest = text.strip_prefix(b"gitdir: ").ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{}: not a gitdir file", dot.display()),
                )
            })?;
            let rest = rest.strip_suffix(b"\n").unwrap_or(rest);
            let rest = rest.strip_suffix(b"\r").unwrap_or(rest);
            let named = PathBuf::from(OsStr::from_bytes(rest));
            if named.is_absolute() {
                named
            } else {
                top.join(named)
            }
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{}: neither a directory nor a gitdir file", dot.display()),
            ));
        };
        Ok(Git {
            git_dir,
            work_tree: Some(top.to_path_buf()),
        })
    }

    /// A git command with `args`, hardened as the module says: the runner's tool environment (no `GIT_*` variable of its
    /// own comes through) and the variables below. Its stdin is null unless the caller gives it input ([`spawn`]).
    pub fn cmd<I, S>(&self, args: I) -> draugr::Spec
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut a: Vec<OsString> = HARDENING.iter().map(OsString::from).collect();
        if let Some(w) = &self.work_tree {
            let mut o = OsString::from("--work-tree=");
            o.push(w);
            a.push(o);
        }
        a.extend(args.into_iter().map(|s| s.as_ref().to_os_string()));
        draugr::Spec {
            program: "git".into(),
            args: a,
            env: crate::tool::tool_env_os(&[
                ("GIT_DIR", self.git_dir.as_os_str()),
                ("GIT_CONFIG_NOSYSTEM", OsStr::new("1")),
                ("GIT_CONFIG_GLOBAL", OsStr::new("/dev/null")),
                ("GIT_TERMINAL_PROMPT", OsStr::new("0")),
            ]),
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        }
    }
}

/// `spec` with the variable KEY set to VALUE (replacing one of that name).
pub(crate) fn set_env(spec: &mut draugr::Spec, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) {
    let key = key.as_ref();
    spec.env.retain(|(k, _)| k != key);
    spec.env
        .push((key.to_os_string(), value.as_ref().to_os_string()));
}

/// What a finished git command left: its exit code, stdout and stderr.
pub(crate) struct Ran {
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Ran {
    pub fn failed(&self, what: &'static str) -> SyncError {
        let tail = &self.stderr[self.stderr.len().saturating_sub(2000)..];
        SyncError::Git {
            what,
            code: self.code,
            stderr: String::from_utf8_lossy(tail).trim_end().to_string(),
        }
    }
}

/// How long one git command may run (a fetch of a big origin over a slow link is the longest) before its group is killed.
const GIT_LIMIT: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Runs `cmd`, feeding it `input` on stdin (the feed and the reads run together, so a full stdout pipe never blocks it).
pub(crate) fn spawn(mut cmd: draugr::Spec, input: Option<&[u8]>) -> io::Result<Ran> {
    cmd.stdin_null = input.is_none();
    // a git that exits early closes the pipe; its exit code says why
    let out = draugr::run_with_input(cmd, input.unwrap_or_default().to_vec(), GIT_LIMIT)?;
    Ok(Ran {
        code: out.status.code(),
        stdout: out.stdout,
        stderr: out.stderr.into_bytes(),
    })
}

/// Runs `cmd` and returns its stdout, or the failure when it exits non-zero.
pub(crate) fn run(what: &'static str, cmd: draugr::Spec, input: Option<&[u8]>) -> Result<Vec<u8>> {
    let ran = spawn(cmd, input)?;
    if ran.code == Some(0) {
        Ok(ran.stdout)
    } else {
        Err(ran.failed(what))
    }
}

/// The first line of git's output, as a string (an object id).
pub(crate) fn line(out: &[u8]) -> String {
    let end = out.iter().position(|&b| b == b'\n').unwrap_or(out.len());
    String::from_utf8_lossy(&out[..end]).into_owned()
}
