//! A child process of a test, started through draugr (the processes standard) with exactly the environment the test
//! gives, and ended with its whole process group when the test is done.

use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::time::Duration;

/// A child the test talks to through its stdout, killed (its group too) and reaped when dropped.
pub struct TestChild {
    // the child's reactor lives here: dropped after the child
    exec: saman::Executor,
    child: draugr::Child,
    out: Option<BufReader<File>>,
    waited: bool,
}

impl TestChild {
    /// Start PROGRAM with ARGS and `PATH`, `LANG` and the `RUST_*` variables of this process plus ENV (`name = value`
    /// pairs), stdin closed. Its stdout is read by [`TestChild::read_line`].
    pub fn start(
        program: &Path,
        args: &[&OsStr],
        env: &[(&str, &OsStr)],
    ) -> villa::Result<TestChild> {
        let exec = saman::Executor::new(1)?;
        let spec = draugr::Spec {
            program: program.to_path_buf(),
            args: args.iter().map(|a| OsString::from(*a)).collect(),
            env: draugr::env::build(&["PATH", "LANG"], &["RUST_"], env),
            cwd: None,
            stdin_null: true,
            pass_fds: vec![],
            new_session: false,
        };
        let mut child = exec.block_on(draugr::spawn(spec)).map_err(|e| {
            villa::Error::from(e).with_detail(format!("starting {}", program.display()))
        })?;
        let out = child
            .take_stdout()
            .map(|s| s.into_owned_fd())
            .transpose()?
            .map(|fd| BufReader::new(File::from(fd)));
        Ok(TestChild {
            exec,
            child,
            out,
            waited: false,
        })
    }

    /// The child's process id (its group's too).
    pub fn pid(&self) -> i32 {
        self.child.id()
    }

    /// The next line the child writes to stdout, with its newline; blocks until it is written.
    pub fn read_line(&mut self) -> villa::Result<String> {
        let out = self
            .out
            .as_mut()
            .ok_or_else(|| villa::Error::invalid("the child's stdout was taken"))?;
        let mut line = String::new();
        out.read_line(&mut line)?;
        Ok(line)
    }

    /// Wait for the child to exit on its own and give its status; an error when it was already waited for.
    pub fn wait(&mut self) -> villa::Result<std::process::ExitStatus> {
        let child = &mut self.child;
        let status = self
            .exec
            .block_on(child.wait())?
            .ok_or_else(|| villa::Error::invalid("the child was already waited for"))?;
        self.waited = true;
        Ok(status)
    }

    /// End the child and its group, and wait until it is gone. Again, or after it exited, it does nothing.
    pub fn kill(&mut self) {
        if self.waited {
            return;
        }
        self.waited = true;
        let pid = self.child.id();
        let child = &mut self.child;
        self.exec.block_on(async {
            let outcome =
                draugr::kill_group(pid, Duration::from_millis(200), &draugr::RealSignaller).await;
            tracing::debug!(pid, ?outcome, "test child ended");
            if let Err(e) = child.wait().await {
                tracing::warn!(pid, "waiting for a test child: {e}");
            }
        });
    }
}

impl Drop for TestChild {
    fn drop(&mut self) {
        self.kill();
    }
}
