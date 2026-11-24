//! A child run to its end, `std::process::Command`-shaped, through `draugr` (docs/develop/standards/processes.md): the git and
//! tool calls the hub and its tests make and wait for. Its group is ended when [`DEADLINE`] passes. Long-lived children
//! (a hub, a job) are `draugr::spawn`'s, not this.
//!
//! The child gets this process's environment, less what [`Command::env_remove`] and [`Command::env_clear`] take away and
//! plus what [`Command::env`] adds (as `std`'s command does). Its stderr is the last of it, as draugr keeps it.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::Duration;

/// How long a child may run before its process group is ended: a build or a clone, never a service.
pub const DEADLINE: Duration = Duration::from_secs(30 * 60);

/// What a child printed and how it ended.
#[derive(Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// A command to run to its end.
#[derive(Debug, Clone)]
pub struct Command {
    program: OsString,
    args: Vec<OsString>,
    clear: bool,
    // None removes the variable
    env: BTreeMap<OsString, Option<OsString>>,
    cwd: Option<PathBuf>,
}

impl Command {
    pub fn new(program: impl AsRef<OsStr>) -> Command {
        Command {
            program: program.as_ref().to_owned(),
            args: Vec::new(),
            clear: false,
            env: BTreeMap::new(),
            cwd: None,
        }
    }

    pub fn arg(&mut self, a: impl AsRef<OsStr>) -> &mut Command {
        self.args.push(a.as_ref().to_owned());
        self
    }

    pub fn args<I, S>(&mut self, args: I) -> &mut Command
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.args
            .extend(args.into_iter().map(|a| a.as_ref().to_owned()));
        self
    }

    pub fn env(&mut self, k: impl AsRef<OsStr>, v: impl AsRef<OsStr>) -> &mut Command {
        self.env
            .insert(k.as_ref().to_owned(), Some(v.as_ref().to_owned()));
        self
    }

    pub fn envs<I, K, V>(&mut self, vars: I) -> &mut Command
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<OsStr>,
        V: AsRef<OsStr>,
    {
        for (k, v) in vars {
            self.env(k, v);
        }
        self
    }

    pub fn env_remove(&mut self, k: impl AsRef<OsStr>) -> &mut Command {
        self.env.insert(k.as_ref().to_owned(), None);
        self
    }

    pub fn env_clear(&mut self) -> &mut Command {
        self.clear = true;
        self.env.clear();
        self
    }

    /// Accepted for the shape of `std`'s command and ignored: a child's stdin is always closed.
    pub fn stdin(&mut self, _: impl Into<std::process::Stdio>) -> &mut Command {
        self
    }

    /// Accepted for the shape of `std`'s command and ignored: a child's stdout is always kept.
    pub fn stdout(&mut self, _: impl Into<std::process::Stdio>) -> &mut Command {
        self
    }

    /// Accepted for the shape of `std`'s command and ignored: the tail of a child's stderr is always kept.
    pub fn stderr(&mut self, _: impl Into<std::process::Stdio>) -> &mut Command {
        self
    }

    pub fn current_dir(&mut self, dir: impl AsRef<Path>) -> &mut Command {
        self.cwd = Some(dir.as_ref().to_owned());
        self
    }

    /// The environment the child gets.
    fn environment(&self) -> Vec<(OsString, OsString)> {
        let mut vars: BTreeMap<OsString, OsString> = if self.clear {
            BTreeMap::new()
        } else {
            std::env::vars_os().collect()
        };
        for (k, v) in &self.env {
            match v {
                Some(v) => {
                    vars.insert(k.clone(), v.clone());
                }
                None => {
                    vars.remove(k);
                }
            }
        }
        vars.into_iter().collect()
    }

    /// Run to the end, its stdout and the tail of its stderr kept; its stdin is closed.
    pub fn output(&mut self) -> io::Result<Output> {
        let spec = draugr::Spec {
            program: self.program.clone().into(),
            args: self.args.clone(),
            env: self.environment(),
            cwd: self.cwd.clone(),
            stdin_null: true,
            pass_fds: Vec::new(),
            new_session: false,
        };
        // on a thread of its own: `draugr::run` starts a runtime, which a caller already inside one cannot
        let run = saman::spawn_thread("proc-run", move || draugr::run(spec, DEADLINE))
            .map_err(io::Error::other)?
            .join()
            .map_err(|_| io::Error::other("the thread running the child panicked"))??;
        Ok(Output {
            status: run.status,
            stdout: run.stdout,
            stderr: run.stderr.into_bytes(),
        })
    }

    /// Run to the end and give its status (its output is kept and dropped).
    pub fn status(&mut self) -> io::Result<ExitStatus> {
        self.output().map(|o| o.status)
    }

    /// [`Command::output`] for an async caller: the child runs on a thread of its own, and the caller awaits it.
    pub async fn output_async(&mut self) -> io::Result<Output> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let mut me = self.clone();
        saman::spawn_thread("proc-run", move || {
            saman::delivered(tx.send(me.output()), "a child's output");
        })
        .map_err(io::Error::other)?;
        rx.await
            .map_err(|_| io::Error::other("the thread running the child ended without an answer"))?
    }

    /// [`Command::status`] for an async caller.
    pub async fn status_async(&mut self) -> io::Result<ExitStatus> {
        self.output_async().await.map(|o| o.status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_child_gives_its_output_and_status() {
        let out = Command::new("sh")
            .args(["-c", "printf out; printf err >&2; exit 3"])
            .output()
            .unwrap();
        assert_eq!(out.stdout, b"out");
        assert_eq!(out.stderr, b"err");
        assert_eq!(out.status.code(), Some(3));
        assert!(Command::new("true").status().unwrap().success());
    }

    #[test]
    fn the_environment_is_ours_less_what_is_removed_and_plus_what_is_added() {
        let sh = |c: &mut Command| {
            let out = c
                .args(["-c", "printf '%s|%s' \"$PATH\" \"$PROC_TEST\""])
                .output()
                .unwrap();
            String::from_utf8(out.stdout).unwrap()
        };
        let ours = std::env::var("PATH").unwrap();
        assert_eq!(
            sh(Command::new("sh").env("PROC_TEST", "yes")),
            format!("{ours}|yes")
        );
        assert_eq!(
            sh(Command::new("sh")
                .env("PROC_TEST", "gone")
                .env_remove("PROC_TEST")),
            format!("{ours}|")
        );
        // with the environment cleared the child has none of ours (a shell makes its own PATH, so look at HOME)
        let home = |c: &mut Command| {
            let out = c
                .args(["-c", "printf '%s' \"${HOME-unset}\""])
                .output()
                .unwrap();
            String::from_utf8(out.stdout).unwrap()
        };
        if let Ok(ours) = std::env::var("HOME") {
            assert_eq!(home(&mut Command::new("/bin/sh")), ours);
        }
        assert_eq!(home(Command::new("/bin/sh").env_clear()), "unset");
    }

    #[test]
    fn a_child_runs_in_the_directory_it_is_given() {
        let dir = tempfile::tempdir().unwrap();
        let out = Command::new("pwd")
            .current_dir(dir.path())
            .output()
            .unwrap();
        let got = String::from_utf8(out.stdout).unwrap();
        assert_eq!(
            std::fs::canonicalize(got.trim()).unwrap(),
            std::fs::canonicalize(dir.path()).unwrap()
        );
    }

    #[test]
    fn a_missing_program_is_an_error_not_a_status() {
        assert!(Command::new("/nonexistent/program").output().is_err());
    }

    #[test]
    fn it_runs_from_inside_a_runtime_too() {
        saman::block_on_current(async {
            assert!(Command::new("true").status().unwrap().success());
        });
    }
}
