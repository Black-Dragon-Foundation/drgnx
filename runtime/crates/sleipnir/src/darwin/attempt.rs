//! A Mac attempt's process. launchd can't take a job from an ssh login (its Background session refuses
//! `bootstrap user/<uid>`: spike S1), so job-exec is started in a session of its own (`setsid`), which outlives the
//! link; a pid file with its start time names it after `serve` is gone. It is alive while that pid still has that
//! start time (a reused pid is not), and it is stopped by SIGKILL to its process group: job-exec and every process
//! that stayed in its group. Processes that left the group are the watchdog's to find (by session and marker).
//! Plain Unix: the rows run on Linux too.

use crate::linux::reserve;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// The attempt's pid file: `<pid> <start time>`.
pub const PID: &str = "job-exec.pid";
/// What job-exec itself prints before its log is open (its own errors).
pub const EXEC_LOG: &str = "job-exec.log";

/// Starts PROGRAM ARGS in a new session at NICE (a workstation's jobs yield to its user: every process of the job
/// inherits it), with DIR's [`EXEC_LOG`] as its output, and records it in DIR's [`PID`]: its pid. While this process
/// lives it reaps the child (a thread waits on it); after, launchd does.
pub fn launch(dir: &Path, program: &Path, args: &[&OsStr], nice: i32) -> io::Result<u32> {
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(EXEC_LOG))?;
    let mut c = Command::new(program);
    c.args(args)
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // SAFETY: setsid and setpriority are async-signal-safe and touch nothing of the parent's
    unsafe {
        c.pre_exec(move || {
            rustix::process::setsid().map_err(io::Error::from)?;
            if nice != 0 && libc::setpriority(libc::PRIO_PROCESS, 0, nice) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = c.spawn()?;
    let pid = child.id();
    // read before the reaper runs: an exited child stays a zombie (and readable) until it is waited for
    let start = reserve::start_time(pid).unwrap_or(0);
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    let tmp = dir.join(format!(".{PID}.tmp"));
    let mut f = fs::File::create(&tmp)?;
    writeln!(f, "{pid} {start}")?;
    drop(f);
    fs::rename(&tmp, dir.join(PID))?;
    Ok(pid)
}

/// DIR's job-exec: its pid and start time, from [`PID`].
pub fn read_pid(dir: &Path) -> Option<(u32, u64)> {
    let text = fs::read_to_string(dir.join(PID)).ok()?;
    let mut w = text.split_whitespace();
    Some((w.next()?.parse().ok()?, w.next()?.parse().ok()?))
}

/// Whether DIR's job-exec still runs.
pub fn active(dir: &Path) -> bool {
    read_pid(dir).is_some_and(|(pid, start)| start != 0 && reserve::alive(pid, start))
}

/// SIGKILL to DIR's job-exec's process group, while it is still the process the pid file names; one that is gone is
/// no error.
pub fn kill(dir: &Path) -> io::Result<()> {
    let Some((pid, start)) = read_pid(dir) else {
        return Ok(());
    };
    if start == 0 || !reserve::alive(pid, start) {
        return Ok(());
    }
    // SAFETY: a plain killpg of a process group we started and checked above
    if unsafe { libc::killpg(pid as libc::pid_t, libc::SIGKILL) } != 0 {
        let e = io::Error::last_os_error();
        if e.raw_os_error() != Some(libc::ESRCH) {
            return Err(e);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fn sh(dir: &Path, script: &str) -> u32 {
        launch(
            dir,
            Path::new("/bin/sh"),
            &[OsStr::new("-c"), OsStr::new(script)],
            0,
        )
        .unwrap()
    }

    /// Whether PID is gone (or only a zombie its parent hasn't waited for yet).
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fn gone(pid: u32) -> bool {
        if cfg!(target_os = "macos") {
            // an orphan is launchd's, which reaps it at once
            // SAFETY: signal 0 only checks that the process exists
            return unsafe { libc::kill(pid as libc::pid_t, 0) } != 0;
        }
        match fs::read_to_string(format!("/proc/{pid}/stat")) {
            Err(_) => true,
            Ok(s) => s
                .rsplit(')')
                .next()
                .is_some_and(|rest| rest.trim_start().starts_with('Z')),
        }
    }

    /// [D] An attempt starts in a session of its own (it outlives the link: the session leader is job-exec, not
    /// sshd's), its pid file names it, and it is active while it runs; after it ends it isn't.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn an_attempt_runs_in_its_own_session() {
        let d = tempfile::tempdir().unwrap();
        let done = d.path().join("done");
        let pid = sh(
            d.path(),
            &format!("while [ ! -e '{}' ]; do sleep 0.05; done", done.display()),
        );
        assert_eq!(read_pid(d.path()).map(|p| p.0), Some(pid));
        let sid = rustix::process::getsid(rustix::process::Pid::from_raw(pid as i32)).unwrap();
        assert_eq!(sid.as_raw_nonzero().get() as u32, pid);
        assert_ne!(
            Some(sid),
            rustix::process::getsid(None).ok(),
            "not this test's session"
        );
        assert!(active(d.path()));
        fs::write(&done, "").unwrap();
        skuld::wait_until("the attempt ends", 30, || (!active(d.path())).then_some(()));
    }

    /// [D] Stop kills the attempt's whole group: job-exec and a child it left running in the background; after, it is
    /// not active, and a second stop is no error.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn stop_leaves_no_process_of_the_group() {
        let d = tempfile::tempdir().unwrap();
        let bg = d.path().join("bg");
        sh(
            d.path(),
            &format!("sleep 300 & echo $! > '{}'; wait", bg.display()),
        );
        let child: u32 = skuld::wait_until("the background child", 30, || {
            fs::read_to_string(&bg).ok()?.trim().parse().ok()
        });
        assert!(active(d.path()));
        kill(d.path()).unwrap();
        skuld::wait_until("the group is gone", 30, || {
            (!active(d.path()) && gone(child)).then_some(())
        });
        kill(d.path()).unwrap();
    }

    /// [D] A workstation's attempt runs niced: job-exec and what it starts yield to the user's own work.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_workstation_attempt_runs_niced() {
        let d = tempfile::tempdir().unwrap();
        let done = d.path().join("done");
        let script = format!("while [ ! -e '{}' ]; do sleep 0.05; done", done.display());
        let pid = launch(
            d.path(),
            Path::new("/bin/sh"),
            &[OsStr::new("-c"), OsStr::new(&script)],
            10,
        )
        .unwrap();
        let prio = rustix::process::getpriority_process(rustix::process::Pid::from_raw(pid as i32));
        fs::write(&done, "").unwrap();
        assert_eq!(prio.unwrap(), 10);
        skuld::wait_until("the attempt ends", 30, || (!active(d.path())).then_some(()));
    }

    /// [D] A pid file whose process is gone, or another process under that pid (another start time), is not active,
    /// and stopping it signals nothing.
    #[test]
    fn a_stale_pid_file_is_not_active() {
        let d = tempfile::tempdir().unwrap();
        let me = std::process::id();
        let t = reserve::start_time(me).unwrap();
        fs::write(d.path().join(PID), format!("{me} {}\n", t + 1)).unwrap();
        assert!(!active(d.path()));
        kill(d.path()).unwrap();
        fs::write(d.path().join(PID), "garbage").unwrap();
        assert!(!active(d.path()));
        assert!(read_pid(d.path()).is_none());
    }
}
