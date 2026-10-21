//! One hub per data dir (design 3.2; review I2, I3): an exclusive `flock` on `hub-HASH.sock.lock`, held for the hub's
//! life (the kernel drops it when the process ends, so a crashed hub leaves no stale lock), with `"PID START_TIME\n"`
//! inside for display.
//!
//! A Lisp hub from before Ratatoskr locks the same path as a *directory* holding `pid` (`drgnx-hub--take-lock`).
//! While that pid is alive and its command line names `drgnx-hub-main`, the directory is respected, whether or not
//! the Lisp hub answers a ping: one too busy to answer is exactly what its lock is for.  A directory whose `pid` does
//! not read is a Lisp hub between its `mkdir` and its pid write while it is younger than [`LISP_LOCK_GRACE`].
//! Anything else (the pid gone, another program, an unreadable pid in an older directory) is taken over.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How long a Lisp lock directory without a readable pid counts as one being made.
pub const LISP_LOCK_GRACE: Duration = Duration::from_secs(10);

/// What `serve` says (and exits 3 with) while a Lisp hub holds the lock.
pub const LISP_HUB_SERVES: &str = "a Lisp hub from before Ratatoskr serves here: drgnx hub stop";

/// The lock, held until dropped.
pub struct Lock {
    _file: File,
    pub path: PathBuf,
}

#[derive(Debug)]
pub enum LockError {
    /// A Lisp hub holds its lock directory here (exit 3).
    LispHub { pid: Option<u32> },
    /// Another Ratatoskr holds the lock (exit 3).
    Held,
    /// The lock cannot be taken for another reason (exit 1).
    Io(io::Error),
}

/// What the lock needs to know about other processes; the tests give their own.
pub trait Procs {
    /// `kill(pid, 0)` succeeds or fails with EPERM.
    fn alive(&self, pid: u32) -> bool;
    /// The process's command line has the argument `drgnx-hub-main`.
    fn is_lisp_hub(&self, pid: u32) -> bool;
}

/// The real processes.
pub struct System;

impl Procs for System {
    fn alive(&self, pid: u32) -> bool {
        alive(pid)
    }

    fn is_lisp_hub(&self, pid: u32) -> bool {
        command_line(pid).is_some_and(|args| args.iter().any(|a| a == b"drgnx-hub-main"))
    }
}

/// What to do with a Lisp hub's lock directory.
#[derive(Debug, PartialEq, Eq)]
pub enum LispLock {
    Respect,
    TakeOver,
}

/// The decision on a Lisp lock directory whose `pid` file read as PID (none when it does not read) and whose age is
/// AGE.
pub fn judge_lisp_lock(pid: Option<u32>, age: Duration, procs: &impl Procs) -> LispLock {
    match pid {
        // a live Lisp hub, answering or not
        Some(pid) if procs.alive(pid) && procs.is_lisp_hub(pid) => LispLock::Respect,
        Some(_) => LispLock::TakeOver,
        // between the Lisp hub's mkdir and its pid write
        None if age < LISP_LOCK_GRACE => LispLock::Respect,
        None => LispLock::TakeOver,
    }
}

/// Take the lock at PATH (`hub-HASH.sock.lock`), first judging a Lisp hub's lock directory there.
pub fn acquire(path: &Path, procs: &impl Procs) -> Result<Lock, LockError> {
    if let Ok(meta) = std::fs::symlink_metadata(path)
        && meta.is_dir()
    {
        let pid = read_pid(&path.join("pid"));
        // a directory whose time is ahead of the clock counts as new: never take a lock over on a guess
        let age = meta
            .modified()
            .ok()
            .and_then(|t| SystemTime::now().duration_since(t).ok())
            .unwrap_or(Duration::ZERO);
        match judge_lisp_lock(pid, age, procs) {
            LispLock::Respect => return Err(LockError::LispHub { pid }),
            LispLock::TakeOver => {
                match std::fs::remove_dir_all(path) {
                    Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(LockError::Io(e)),
                    _ => {}
                }
                tracing::warn!(
                    pid,
                    "took over a stale Lisp hub's lock directory {}",
                    path.display()
                );
            }
        }
    }
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| match e.raw_os_error() {
            // a Lisp hub made its directory since the check above
            Some(libc::EISDIR) => LockError::LispHub { pid: None },
            _ => LockError::Io(e),
        })?;
    match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => {}
        Err(rustix::io::Errno::WOULDBLOCK) => return Err(LockError::Held),
        Err(e) => return Err(LockError::Io(e.into())),
    }
    let me = std::process::id();
    let started = i32::try_from(me)
        .ok()
        .and_then(|p| draugr::start_time(p).ok())
        .unwrap_or(0);
    file.set_len(0)
        .and_then(|()| file.write_all(format!("{me} {started}\n").as_bytes()))
        .map_err(LockError::Io)?;
    Ok(Lock {
        _file: file,
        path: path.to_path_buf(),
    })
}

/// What holds the lock at a path, seen from another process (`ensure`, `stop`).
#[derive(Debug, PartialEq, Eq)]
pub enum Holder {
    /// Nothing: no file, a file nobody holds, or a stale Lisp lock directory.
    Nobody,
    /// A Ratatoskr holds the `flock`; the file says `"PID START_TIME"` (none where it does not read).
    Ratatoskr {
        pid: Option<u32>,
        start: Option<u64>,
    },
    /// A Lisp hub's lock directory that [`judge_lisp_lock`] respects (its pid, when it reads).
    Lisp { pid: Option<u32> },
}

/// The Lisp lock directory at PATH, as [`acquire`] would judge it: its pid and whether it is respected.  None when
/// PATH is not a directory.
pub fn lisp_dir(path: &Path, procs: &impl Procs) -> Option<(Option<u32>, LispLock)> {
    let meta = std::fs::symlink_metadata(path)
        .ok()
        .filter(|m| m.is_dir())?;
    let pid = read_pid(&path.join("pid"));
    let age = meta
        .modified()
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .unwrap_or(Duration::ZERO);
    Some((pid, judge_lisp_lock(pid, age, procs)))
}

/// Who holds the lock at PATH.  A Ratatoskr's file is probed with `flock(LOCK_EX|LOCK_NB)`: it succeeding means
/// nobody holds it (released again at once), so a stale file naming a live pid is no holder at all.
pub fn holder(path: &Path, procs: &impl Procs) -> io::Result<Holder> {
    if let Some((pid, verdict)) = lisp_dir(path, procs) {
        return Ok(match verdict {
            LispLock::Respect => Holder::Lisp { pid },
            LispLock::TakeOver => Holder::Nobody,
        });
    }
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Holder::Nobody),
        Err(e) => return Err(e),
    };
    match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => return Ok(Holder::Nobody),
        Err(rustix::io::Errno::WOULDBLOCK) => {}
        Err(e) => return Err(e.into()),
    }
    let mut text = String::new();
    let _ = (&mut file).take(64).read_to_string(&mut text);
    let mut fields = text.split_whitespace();
    let pid = fields
        .next()
        .and_then(|p| p.parse().ok())
        .filter(|p| *p > 0);
    let start = fields.next().and_then(|s| s.parse().ok());
    Ok(Holder::Ratatoskr { pid, start })
}

/// The pid `stop` may signal for a held lock that names PID and START: only the process whose start time now is
/// the recorded one (a pid reused since is another process).  CURRENT is that pid's start time now (none: gone).
pub fn signal_target(
    pid: Option<u32>,
    start: Option<u64>,
    current: impl Fn(u32) -> Option<u64>,
) -> Result<u32, String> {
    let (Some(pid), Some(start)) = (pid, start) else {
        return Err("the lock is held but does not name a process".into());
    };
    match current(pid) {
        Some(now) if now == start => Ok(pid),
        Some(now) => Err(format!(
            "the lock names pid {pid} started at {start}, but that pid started at {now} (another process): not signalling it"
        )),
        None => Err(format!("the lock names pid {pid}, which is gone")),
    }
}

/// The pid in a Lisp lock directory's `pid` file (at most 32 bytes; anything but a number is none).
fn read_pid(file: &Path) -> Option<u32> {
    let mut text = String::new();
    File::open(file)
        .ok()?
        .take(32)
        .read_to_string(&mut text)
        .ok()?;
    text.trim().parse().ok().filter(|p| *p > 0)
}

/// Is PID a process ([`draugr::alive`]; a number above `i32::MAX` is none)?
pub fn alive(pid: u32) -> bool {
    i32::try_from(pid).is_ok_and(draugr::alive)
}

/// The arguments of PID (Linux and Android `/proc/PID/cmdline`, macOS `sysctl KERN_PROCARGS2`; any other platform has
/// none, below); none when they cannot be read.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn command_line(pid: u32) -> Option<Vec<Vec<u8>>> {
    let mut raw = Vec::new();
    File::open(format!("/proc/{pid}/cmdline"))
        .ok()?
        .take(1 << 20)
        .read_to_end(&mut raw)
        .ok()?;
    Some(
        raw.split(|b| *b == 0)
            .filter(|a| !a.is_empty())
            .map(<[u8]>::to_vec)
            .collect(),
    )
}

/// The arguments of PID (Linux `/proc/PID/cmdline`, macOS `sysctl KERN_PROCARGS2`); none when they cannot be read.
#[cfg(target_os = "macos")]
pub fn command_line(pid: u32) -> Option<Vec<Vec<u8>>> {
    // KERN_PROCARGS2: argc (an int), the executable's path, NUL padding, then argc NUL-terminated arguments
    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        i32::try_from(pid).ok()?,
    ];
    let mut size: libc::size_t = 0;
    let probe = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if probe != 0 || size < 4 {
        return None;
    }
    let mut buf = vec![0u8; size];
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || size < 4 {
        return None;
    }
    buf.truncate(size);
    let argc = i32::from_ne_bytes(buf[..4].try_into().ok()?);
    let rest = &buf[4..];
    let path_end = rest.iter().position(|b| *b == 0)?;
    let mut parts = rest[path_end..]
        .split(|b| *b == 0)
        .filter(|a| !a.is_empty());
    Some(
        (0..argc.max(0))
            .map_while(|_| parts.next().map(<[u8]>::to_vec))
            .collect(),
    )
}

/// The arguments of PID on a platform with no way to read them: none, so a lock holder is never taken for a Rust hub
/// and the lock is not stolen (Android stance: unsupported here; Android has `/proc`, so it takes the Linux branch).
#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
pub fn command_line(_pid: u32) -> Option<Vec<Vec<u8>>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// Processes as the test says: (pid, is it a Lisp hub).
    struct Fake(Vec<(u32, bool)>);

    impl Procs for Fake {
        fn alive(&self, pid: u32) -> bool {
            self.0.iter().any(|p| p.0 == pid)
        }
        fn is_lisp_hub(&self, pid: u32) -> bool {
            self.0.iter().any(|p| p.0 == pid && p.1)
        }
    }

    const YOUNG: Duration = Duration::from_secs(1);
    const OLD: Duration = Duration::from_secs(60);

    #[test]
    fn a_live_lisp_hub_is_respected_busy_or_not() {
        let procs = Fake(vec![(100, true), (200, false)]);
        // alive and a Lisp hub: respected at any age (nothing here asks whether it answers)
        assert_eq!(judge_lisp_lock(Some(100), OLD, &procs), LispLock::Respect);
        assert_eq!(judge_lisp_lock(Some(100), YOUNG, &procs), LispLock::Respect);
        // alive but another program (a reused pid): taken over
        assert_eq!(
            judge_lisp_lock(Some(200), YOUNG, &procs),
            LispLock::TakeOver
        );
        // gone: taken over
        assert_eq!(
            judge_lisp_lock(Some(300), YOUNG, &procs),
            LispLock::TakeOver
        );
        // no readable pid: a Lisp hub being made while young, stale when old
        assert_eq!(judge_lisp_lock(None, YOUNG, &procs), LispLock::Respect);
        assert_eq!(judge_lisp_lock(None, OLD, &procs), LispLock::TakeOver);
    }

    #[test]
    fn the_real_processes() {
        let me = std::process::id();
        assert!(alive(me));
        assert!(!System.is_lisp_hub(me), "this test is no Lisp hub");
        assert!(command_line(me).is_some_and(|a| !a.is_empty()));
        // pid 1 exists and is not ours: EPERM counts as alive
        assert!(alive(1));
        // no child is spawned here: a fork in this process would hold the other test's lock until its exec
        assert!(!alive(0) && !alive(u32::MAX), "not pids");
    }

    #[test]
    fn the_holder_is_probed_not_believed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hub-x.sock.lock");
        assert_eq!(holder(&path, &Fake(vec![])).unwrap(), Holder::Nobody);
        // a file naming a live pid that nobody holds: no holder
        std::fs::write(&path, "100 7\n").unwrap();
        assert_eq!(
            holder(&path, &Fake(vec![(100, false)])).unwrap(),
            Holder::Nobody
        );
        // held: the file's pid and start time
        let held = acquire(&path, &Fake(vec![])).unwrap();
        let me = std::process::id();
        match holder(&path, &Fake(vec![])).unwrap() {
            Holder::Ratatoskr {
                pid: Some(p),
                start: Some(_),
            } => assert_eq!(p, me),
            other => panic!("{other:?}"),
        }
        drop(held);
        // the probe released what it took: the lock can be taken
        drop(acquire(&path, &Fake(vec![])).unwrap());
        std::fs::remove_file(&path).unwrap();
        // a Lisp directory: respected while its hub lives, else nobody
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("pid"), "100").unwrap();
        assert_eq!(
            holder(&path, &Fake(vec![(100, true)])).unwrap(),
            Holder::Lisp { pid: Some(100) }
        );
        assert_eq!(holder(&path, &Fake(vec![])).unwrap(), Holder::Nobody);
    }

    #[test]
    fn only_the_recorded_process_is_a_signal_target() {
        let same = |_: u32| Some(5);
        assert_eq!(signal_target(Some(9), Some(5), same), Ok(9));
        // a reused pid (another start time) and a gone one are refused
        assert!(signal_target(Some(9), Some(4), same).is_err());
        assert!(signal_target(Some(9), Some(5), |_| None).is_err());
        // a lock that names nobody
        assert!(signal_target(None, Some(5), same).is_err());
        assert!(signal_target(Some(9), None, same).is_err());
    }

    #[test]
    fn a_held_lock_refuses_and_a_lisp_directory_is_judged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hub-x.sock.lock");
        let first = acquire(&path, &Fake(vec![])).unwrap();
        assert!(matches!(
            acquire(&path, &Fake(vec![])),
            Err(LockError::Held)
        ));
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(first);
        // released with the descriptor
        let again = acquire(&path, &Fake(vec![])).unwrap();
        drop(again);
        std::fs::remove_file(&path).unwrap();

        // a live Lisp hub's directory: respected and left as it is
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("pid"), "100").unwrap();
        assert!(matches!(
            acquire(&path, &Fake(vec![(100, true)])),
            Err(LockError::LispHub { pid: Some(100) })
        ));
        assert_eq!(std::fs::read_to_string(path.join("pid")).unwrap(), "100");
        // its pid gone: taken over, the directory replaced by the lock file
        let taken = acquire(&path, &Fake(vec![])).unwrap();
        assert!(path.is_file());
        drop(taken);
        std::fs::remove_file(&path).unwrap();

        // a fresh directory with no pid yet: a Lisp hub being made
        std::fs::create_dir(&path).unwrap();
        assert!(matches!(
            acquire(&path, &Fake(vec![])),
            Err(LockError::LispHub { pid: None })
        ));
        assert!(path.is_dir());

        // a link is never followed
        std::fs::remove_dir(&path).unwrap();
        let target = dir.path().join("elsewhere");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(matches!(
            acquire(&path, &Fake(vec![])),
            Err(LockError::Io(_))
        ));
        assert!(!target.exists());
    }
}
