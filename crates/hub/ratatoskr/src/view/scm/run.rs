//! Running git for the Source Control view, always on a thread of the caller's (never the hub's loop), each call with
//! a deadline or a way to stop it.
//!
//! - **Reads** (status, log, branches) are the trusted, read-only git of `draugr::git` (`Place::Trusted`), as the
//!   Explorer's letters are.
//! - **The user's commands** (stage, commit, push, …) run as typing them in a terminal would: the trusted git
//!   program, the user's config, credential helper, ssh agent and the repository's hooks (a commit runs
//!   `pre-commit`, a push `pre-push`). Only an editor, a pager and the `ext` protocol are refused, and a password
//!   prompt is never shown (`GIT_TERMINAL_PROMPT=0`, no terminal). `draugr::git`'s overrides would skip the hooks,
//!   which the user's commit must not.

use draugr::git::{GitCall, Place, command, git_program};
use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// A local command's deadline (stage, unstage, discard, checkout, stash, a read).
pub const LOCAL: Duration = Duration::from_secs(10);
/// A commit's deadline: its hooks may take a while (a lint, a test run).
pub const COMMIT: Duration = Duration::from_secs(300);

/// What git said when it failed, or why it did not run.
pub type GitError = String;

/// Overrides for the user's commands: no editor, no pager, no `ext` protocol.
const USER_OVERRIDES: [&str; 6] = [
    "-c",
    "core.editor=false",
    "-c",
    "core.pager=cat",
    "-c",
    "protocol.ext.allow=never",
];

/// Variables a git hook or a calling git sets, which would point this git at another repository.
const LEAKS: [&str; 6] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_PREFIX",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
];

/// How a call runs.
pub enum As {
    /// The trusted read-only git.
    Reader,
    /// The user's own command.
    User,
}

/// GIT ARGS in ROOT, run AS, with STDIN, stopped at DEADLINE (none: until it ends) or once CANCEL is set (with its
/// group: a push's ssh goes with it). Its output, or git's complaint.
pub fn git(
    root: &Path,
    how: As,
    args: &[&str],
    stdin: Option<&[u8]>,
    deadline: Option<Duration>,
    cancel: Option<&AtomicBool>,
) -> Result<Vec<u8>, GitError> {
    let program = git_program().map_err(|e| e.to_string())?;
    let mut cmd = crate::proc::Command::new(&program.path);
    match how {
        As::Reader => {
            let call = GitCall {
                place: Place::Trusted { read_only: true },
                allow_protocols: vec![],
                args: args.iter().map(OsString::from).collect(),
            };
            let (argv, env) = command(&call).map_err(|e| format!("{e:?}"))?;
            cmd.args(argv).envs(env).env("GIT_OPTIONAL_LOCKS", "0");
        }
        As::User => {
            cmd.args(USER_OVERRIDES)
                .args(args)
                .env("GIT_TERMINAL_PROMPT", "0");
        }
    }
    run(cmd, root, stdin, deadline, cancel)
}

/// CMD in ROOT: see [`git`].
pub fn run(
    mut cmd: crate::proc::Command,
    root: &Path,
    stdin: Option<&[u8]>,
    deadline: Option<Duration>,
    cancel: Option<&AtomicBool>,
) -> Result<Vec<u8>, GitError> {
    use crate::proc::Io;
    for v in LEAKS {
        cmd.env_remove(v);
    }
    cmd.current_dir(root);
    let feed = if stdin.is_some() { Io::Pipe } else { Io::Null };
    let mut child = cmd
        .spawn(feed, Io::Pipe, Io::Pipe)
        .map_err(|e| format!("git: {e}"))?;
    let pid = child.id();
    if let (Some(text), Some(mut w)) = (stdin, child.stdin.take()) {
        let text = text.to_vec();
        crate::soft::done(
            saman::spawn_thread("ratatoskr:run", move || {
                crate::soft::done(w.write_all(&text), "run");
            }),
            "thread",
        );
    }
    let drain = |r: Option<Box<dyn Read + Send>>| {
        saman::spawn_thread("ratatoskr:run", move || {
            let mut buf = Vec::new();
            if let Some(mut r) = r {
                crate::soft::done(r.read_to_end(&mut buf), "run");
            }
            buf
        })
        .map_err(|e| e.message().to_owned())
    };
    let out = drain(
        child
            .stdout
            .take()
            .map(|r| Box::new(r) as Box<dyn Read + Send>),
    )?;
    let err = drain(
        child
            .stderr
            .take()
            .map(|r| Box::new(r) as Box<dyn Read + Send>),
    )?;
    // a thread of its own waits for git: real time, whatever clock the hub runs on
    let end = deadline.map(|d| crate::clock::real_now() + d);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) => {}
            Err(e) => return Err(format!("git: {e}")),
        }
        if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            stop(pid);
            crate::soft::done(child.wait(), "run");
            return Err(STOPPED.to_owned());
        }
        if end.is_some_and(|e| crate::clock::real_now() >= e) {
            stop(pid);
            crate::soft::done(child.wait(), "run");
            let secs = deadline.unwrap_or_default().as_secs();
            return Err(format!("git took longer than {secs} s and was stopped"));
        }
        stund::real::sleep_blocking(Duration::from_millis(5));
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    if status.success() {
        return Ok(out);
    }
    let text = String::from_utf8_lossy(&err);
    let text = text.trim();
    Err(if text.is_empty() {
        match status.code() {
            Some(c) => format!("git failed (exit {c})"),
            None => "git was stopped".to_owned(),
        }
    } else {
        text.to_owned()
    })
}

/// What a stopped command answers.
pub const STOPPED: &str = "stopped";

/// Stop the git whose group PID leads, and everything it started (ssh, a hook).
fn stop(pid: u32) {
    // SAFETY: called only before the child is reaped: PID leads the group we made (`process_group(0)`), so the id
    // names only it.
    unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
}
