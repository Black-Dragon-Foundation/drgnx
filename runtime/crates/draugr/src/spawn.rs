//! Starting a child: an explicit environment, its own process group, SIGPIPE ignored, stderr kept as a bounded
//! tail, exactly one exit status.

use std::ffi::OsString;
use std::io;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::{ChildStdin, ChildStdout, Command};
use tokio::task::JoinHandle;

/// How much of a child's stderr is kept, in characters.
pub const STDERR_TAIL_CHARS: usize = 8000;

/// What to start. `env` is the child's whole environment (build it with [`crate::env::build`]); `cwd` `None` keeps
/// the hub's. With `stdin_null` the child's stdin is `/dev/null`, otherwise a pipe ([`Child::take_stdin`]).
#[derive(Debug, Clone)]
pub struct Spec {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
    pub stdin_null: bool,
}

/// Bytes of stderr kept: enough for [`STDERR_TAIL_CHARS`] characters of up to four bytes each.
const TAIL_BYTES: usize = STDERR_TAIL_CHARS * 4;
/// After the exit, how long [`Child::wait`] lets the stderr reader catch up (a grandchild may hold stderr open).
const TAIL_SETTLE: Duration = Duration::from_millis(200);

/// A running child. Its pid is also its process-group id. Dropped without [`Child::wait`], it keeps running and
/// tokio reaps it when it exits.
pub struct Child {
    inner: tokio::process::Child,
    pid: i32,
    tail: Arc<Mutex<Vec<u8>>>,
    reader: Option<JoinHandle<()>>,
    exited: bool,
}

/// Start `spec`'s program in a process group of its own, with exactly `spec.env` as its environment and SIGPIPE
/// ignored (std resets it to the default in a child; a child writing to a pipe whose reader left gets EPIPE
/// instead of dying). No `PR_SET_PDEATHSIG`: it fires when the forking thread exits, and tokio's threads come and go.
pub async fn spawn(spec: Spec) -> io::Result<Child> {
    let mut cmd = Command::new(&spec.program);
    cmd.args(&spec.args)
        .env_clear()
        .envs(spec.env.iter().map(|(k, v)| (k, v)))
        .stdin(if spec.stdin_null {
            Stdio::null()
        } else {
            Stdio::piped()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    if let Some(cwd) = &spec.cwd {
        cmd.current_dir(cwd);
    }
    // SAFETY: runs in the forked child before exec; signal(2) is async-signal-safe and nothing here allocates.
    // std runs pre_exec closures after it has reset SIGPIPE to the default.
    unsafe {
        cmd.pre_exec(|| {
            if libc::signal(libc::SIGPIPE, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut inner = cmd.spawn()?;
    let pid = inner
        .id()
        .and_then(|p| i32::try_from(p).ok())
        .ok_or_else(|| io::Error::other("the child has no pid"))?;
    let tail = Arc::new(Mutex::new(Vec::new()));
    let reader = inner.stderr.take().map(|mut stderr| {
        let tail = Arc::clone(&tail);
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            while let Ok(n @ 1..) = stderr.read(&mut buf).await {
                let mut t = tail.lock().unwrap_or_else(|e| e.into_inner());
                t.extend_from_slice(&buf[..n]);
                let over = t.len().saturating_sub(TAIL_BYTES);
                t.drain(..over);
            }
        })
    });
    Ok(Child {
        inner,
        pid,
        tail,
        reader,
        exited: false,
    })
}

impl Child {
    /// The child's pid, which is also its process-group id.
    pub fn id(&self) -> i32 {
        self.pid
    }

    /// The child's stdin (a pipe unless the spec had `stdin_null`). [`Child::wait`] closes it if it was not taken.
    pub fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.inner.stdin.take()
    }

    pub fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.inner.stdout.take()
    }

    /// The exit status, once: `Ok(Some(status))` the first time, `Ok(None)` on every later call.
    pub async fn wait(&mut self) -> io::Result<Option<ExitStatus>> {
        if self.exited {
            return Ok(None);
        }
        let status = self.inner.wait().await?;
        self.exited = true;
        if let Some(reader) = self.reader.take() {
            let _ = tokio::time::timeout(TAIL_SETTLE, reader).await;
        }
        Ok(Some(status))
    }

    /// The last [`STDERR_TAIL_CHARS`] characters the child wrote to stderr so far (invalid UTF-8 replaced).
    pub fn stderr_tail(&self) -> String {
        let bytes = self.tail.lock().unwrap_or_else(|e| e.into_inner());
        let text = String::from_utf8_lossy(&bytes);
        let skip = text.chars().count().saturating_sub(STDERR_TAIL_CHARS);
        text.chars().skip(skip).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};

    fn sh(script: &str, stdin_null: bool) -> Spec {
        Spec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            env: crate::env::build(&["PATH"], &[], &[]),
            cwd: None,
            stdin_null,
        }
    }

    #[tokio::test]
    async fn own_process_group_and_sigpipe_ignored() {
        // The shell sends itself SIGPIPE and lives to say so only if it started with SIGPIPE ignored. (Reading the
        // disposition back is not portable: macOS's /bin/sh, bash 3.2, leaves a signal ignored at entry out of `trap`.)
        let mut child = spawn(sh("kill -s PIPE $$; echo alive; read x; exit 0", false))
            .await
            .unwrap();
        let pid = child.id();
        let mut lines = BufReader::new(child.take_stdout().unwrap()).lines();
        let first = lines.next_line().await.unwrap();
        assert_eq!(first.as_deref(), Some("alive"), "the child died of SIGPIPE");
        // While the child waits on its stdin: it leads its own group, not ours.
        assert_eq!(unsafe { libc::getpgid(pid) }, pid);
        assert_ne!(pid, unsafe { libc::getpgrp() });
        drop(child.take_stdin());
        assert!(child.wait().await.unwrap().unwrap().success());
    }

    #[tokio::test]
    async fn exit_reported_once() {
        let mut child = spawn(sh("exit 3", true)).await.unwrap();
        assert_eq!(child.wait().await.unwrap().unwrap().code(), Some(3));
        assert!(child.wait().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn stderr_tail_keeps_the_last_8000_characters() {
        let mut child = spawn(sh(
            "head -c 9000 /dev/zero | tr '\\0' a >&2; printf b >&2",
            true,
        ))
        .await
        .unwrap();
        assert!(child.wait().await.unwrap().unwrap().success());
        let tail = child.stderr_tail();
        assert_eq!(tail.chars().count(), STDERR_TAIL_CHARS);
        assert!(tail.ends_with("ab"), "{}", &tail[tail.len() - 10..]);
    }
}
