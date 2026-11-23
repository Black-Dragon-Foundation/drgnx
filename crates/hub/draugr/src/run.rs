//! A child run to its end by a caller that has no runtime of its own (a build script, a command line, a test): the
//! blocking form of [`crate::spawn`] that keeps stdout.

use std::io;
use std::process::ExitStatus;
use std::time::Duration;

use tokio::io::AsyncReadExt;

use crate::spawn::{Spec, spawn};

/// What a child printed and how it ended.
#[derive(Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    /// The tail of its stderr ([`crate::spawn::STDERR_TAIL_CHARS`] characters).
    pub stderr: String,
}

/// Start SPEC and wait for it on this thread: its stdout is read to the end, and once DEADLINE has passed on the
/// installed clock its whole process group is killed. Not for a thread of a runtime (it makes one): use [`spawn`]
/// there. [`io::ErrorKind::TimedOut`] when the deadline passed before the child closed its stdout.
pub fn run(spec: Spec, deadline: Duration) -> io::Result<Output> {
    let exec = saman::Executor::new(1).map_err(io::Error::other)?;
    exec.block_on(async {
        let mut child = spawn(spec).await?;
        let mut stdout = child.take_stdout();
        let read = async {
            let mut bytes = Vec::new();
            if let Some(out) = stdout.as_mut() {
                out.read_to_end(&mut bytes).await?;
            }
            Ok::<_, io::Error>(bytes)
        };
        let Ok(bytes) = stund::timeout(deadline, read).await else {
            // the child's group is ended and reaped; its stdout never closed in time
            child.wait_deadline(Duration::ZERO).await?;
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the child did not finish in time",
            ));
        };
        let status = child
            .wait_deadline(deadline)
            .await?
            .ok_or_else(|| io::Error::other("the child was already waited for"))?;
        Ok(Output {
            status,
            stdout: bytes?,
            stderr: child.stderr_tail(),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> Spec {
        Spec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: crate::env::build(&["PATH"], &[], &[]),
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        }
    }

    #[test]
    fn a_run_keeps_stdout_the_stderr_tail_and_the_status() {
        let out = run(
            sh("echo out; echo err >&2; exit 3"),
            Duration::from_secs(30),
        )
        .unwrap();
        assert_eq!(out.stdout, b"out\n");
        assert_eq!(out.stderr.trim(), "err");
        assert_eq!(out.status.code(), Some(3));
    }

    #[test]
    fn a_child_that_never_finishes_is_killed_at_the_deadline() {
        let e = run(sh("sleep 600"), Duration::from_millis(200)).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::TimedOut);
    }
}
