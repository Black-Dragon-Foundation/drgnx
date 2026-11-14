//! drgnx-exe: files a program writes or copies and then runs.
//!
//! On Linux, `execve` of a file that any process holds open for writing fails with ETXTBSY.  A child forked by
//! another thread copies the process's file table, the write descriptor included, and keeps it until its own `exec`
//! closes it: so a file written here and run at once can fail to start.  A rename keeps the same file, so it does
//! not help.  Two ways keep the descriptor out of every fork, and [`mode`] says which this process uses:
//!
//! - [`Mode::PrivateTable`]: [`private_fds`] does the writing on a thread with its own file table
//!   (`unshare(CLONE_FILES)`), which no other thread's fork copies.  That table starts as a copy of the process's, so
//!   the thread closes all but 0, 1 and 2 first: otherwise a pipe or socket another thread closes would not end until
//!   the writing does.
//! - [`Mode::Lock`]: where `unshare` is refused (Docker's default seccomp profile answers EPERM, and devcontainers use
//!   it) a process-wide lock does the same job: [`private_fds`] (so [`write`] and [`copy`]) holds it shared while its
//!   descriptor is open, and [`spawn`] holds it exclusively from fork to exec.  The guarantee holds against every
//!   spawn that goes through [`spawn`] (draugr's, which starts every job); a raw `Command::spawn` elsewhere is
//!   outside it.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::{OnceLock, RwLock};

/// How this process keeps a write descriptor out of other threads' forks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// A thread with its own file table (Linux, `unshare(CLONE_FILES)` allowed).
    PrivateTable,
    /// The process-wide lock (Linux, `unshare` refused).
    Lock,
    /// Neither: not Linux, where a write descriptor does not block `exec`.
    Direct,
}

impl Mode {
    /// The word `doctor` prints.
    pub fn name(self) -> &'static str {
        match self {
            Mode::PrivateTable => "private-table",
            Mode::Lock => "lock",
            Mode::Direct => "direct",
        }
    }
}

/// The mode this process uses, found once: `unshare(CLONE_FILES)` tried on a thread of its own.
pub fn mode() -> Mode {
    static MODE: OnceLock<Mode> = OnceLock::new();
    *MODE.get_or_init(probe)
}

#[cfg(target_os = "linux")]
fn probe() -> Mode {
    // `DRGNX_EXE_MODE=lock` takes the lock path on a machine that allows unshare: to run a suite as Docker's default
    // profile would
    if std::env::var_os("DRGNX_EXE_MODE").is_some_and(|m| m == "lock") {
        return Mode::Lock;
    }
    let ok = std::thread::scope(|s| {
        s.spawn(|| {
            // SAFETY: CLONE_FILES alone gives the calling thread a copy of the file table; nothing else changes
            unsafe { libc::unshare(libc::CLONE_FILES) == 0 }
        })
        .join()
        .unwrap_or(false)
    });
    if ok { Mode::PrivateTable } else { Mode::Lock }
}

#[cfg(not(target_os = "linux"))]
fn probe() -> Mode {
    Mode::Direct
}

/// Held shared by every open write descriptor, exclusively by every spawn (in [`Mode::Lock`]).
static FORKS: RwLock<()> = RwLock::new(());

/// F's result, F run with descriptors no other thread's fork can copy: in [`Mode::PrivateTable`] on a thread of its
/// own with its own file table, which starts with only 0, 1 and 2: F opens what it uses; in [`Mode::Lock`] here with
/// every [`spawn`] held off until F returns; in [`Mode::Direct`] here.  A descriptor F leaves open is closed when the
/// thread ends (private table); in lock mode it is no longer protected once F returns.
pub fn private_fds<T: Send>(f: impl FnOnce() -> T + Send) -> std::io::Result<T> {
    private_fds_in(mode(), f)
}

fn private_fds_in<T: Send>(mode: Mode, f: impl FnOnce() -> T + Send) -> std::io::Result<T> {
    match mode {
        #[cfg(target_os = "linux")]
        Mode::PrivateTable => std::thread::scope(|s| {
            s.spawn(|| {
                // SAFETY: CLONE_FILES alone gives the calling thread a copy of the file table; nothing else changes
                if unsafe { libc::unshare(libc::CLONE_FILES) } != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                // the copy holds every descriptor of the process: closed here, or a pipe or socket another thread
                // closes meanwhile would stay open (no EOF) until F ends.  F opens what it needs itself.
                // SAFETY: closes descriptors 3 and up of this thread's own table, which nothing else uses
                if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(f())
            })
            .join()
            .unwrap_or_else(|p| std::panic::resume_unwind(p))
        }),
        Mode::Lock => {
            let _held = FORKS.read().unwrap_or_else(|e| e.into_inner());
            Ok(f())
        }
        _ => Ok(f()),
    }
}

/// F's result, F being a spawn (`Command::spawn`, which returns once the child has exec'd): in [`Mode::Lock`] no
/// write descriptor from [`write`] or [`copy`] is open meanwhile, so the child never holds one; otherwise F runs as
/// it is.  Wrap the spawn only, never the wait for the child.
pub fn spawn<T>(f: impl FnOnce() -> T) -> T {
    spawn_in(mode(), f)
}

fn spawn_in<T>(mode: Mode, f: impl FnOnce() -> T) -> T {
    if mode == Mode::Lock {
        let _held = FORKS.write().unwrap_or_else(|e| e.into_inner());
        return f();
    }
    f()
}

/// PATH made (or replaced) with CONTENTS, mode 0755, its write descriptor never in a table another fork copies.
pub fn write(path: &Path, contents: impl AsRef<[u8]>) -> std::io::Result<()> {
    write_in(mode(), path, contents.as_ref())
}

fn write_in(mode: Mode, path: &Path, contents: &[u8]) -> std::io::Result<()> {
    private_fds_in(mode, || {
        let _ = std::fs::remove_file(path);
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(path)?;
        f.write_all(contents)
    })?
}

/// FROM copied to TO as `std::fs::copy` does (mode included), TO's write descriptor never in a table another fork
/// copies.
pub fn copy(from: &Path, to: &Path) -> std::io::Result<u64> {
    copy_in(mode(), from, to)
}

fn copy_in(mode: Mode, from: &Path, to: &Path) -> std::io::Result<u64> {
    private_fds_in(mode, || std::fs::copy(from, to))?
}

// Linux's: elsewhere nothing here differs from std
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    /// The private table starts with none of the process's descriptors above 2 (a pipe another thread closes while F
    /// runs ends at once); the process keeps its own.
    #[test]
    fn the_private_table_holds_none_of_the_process_descriptors() {
        if mode() != Mode::PrivateTable {
            return; // unshare refused here (Docker's default profile): the lock tests cover it
        }
        use std::os::fd::AsRawFd;
        let file = std::fs::File::open("/dev/null").unwrap();
        let fd = file.as_raw_fd();
        // SAFETY: F_GETFD only reads the descriptor's flags
        let open = move || unsafe { libc::fcntl(fd, libc::F_GETFD) } != -1;
        assert!(
            !private_fds_in(Mode::PrivateTable, open).unwrap(),
            "descriptor {fd} is open in the private table"
        );
        assert!(open(), "descriptor {fd} is still open here");
    }

    /// Each of 300 files, made and run at once while 4 threads spawn all along (through `spawn_in`, as the hub's
    /// spawns do), starts: none is busy.
    fn starts_while_other_threads_fork(mode: Mode, make: impl Fn(&Path, &Path)) {
        // one at a time: the other test's raw spawns are outside the lock, as any raw spawn is
        static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
        use std::sync::atomic::{AtomicBool, Ordering};
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        std::fs::write(&src, b"#!/bin/sh\nexit 0\n").unwrap();
        let stop = AtomicBool::new(false);
        std::thread::scope(|s| {
            for _ in 0..4 {
                s.spawn(|| {
                    while !stop.load(Ordering::Relaxed) {
                        let child =
                            spawn_in(mode, || std::process::Command::new("/bin/true").spawn());
                        let _ = child.and_then(|mut c| c.wait());
                    }
                });
            }
            let mut busy = 0;
            for i in 0..300 {
                let p = d.path().join(format!("x{i}"));
                make(&src, &p);
                match spawn_in(mode, || std::process::Command::new(&p).spawn()) {
                    Ok(mut c) => assert!(c.wait().unwrap().success()),
                    Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => busy += 1,
                    Err(e) => panic!("{}: {e}", p.display()),
                }
            }
            stop.store(true, Ordering::Relaxed);
            assert_eq!(busy, 0, "{busy} of 300 failed to start: ETXTBSY");
        });
    }

    fn write_then_copy(mode: Mode) -> impl Fn(&Path, &Path) {
        move |src, p| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(src, std::fs::Permissions::from_mode(0o755)).unwrap();
            if p.file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .ends_with(['0', '2', '4', '6', '8'])
            {
                write_in(mode, p, b"#!/bin/sh\nexit 0\n").unwrap();
            } else {
                copy_in(mode, src, p).unwrap();
            }
        }
    }

    #[test]
    fn a_file_written_or_copied_here_starts_while_other_threads_fork() {
        if mode() != Mode::PrivateTable {
            return;
        }
        starts_while_other_threads_fork(Mode::PrivateTable, write_then_copy(Mode::PrivateTable));
    }

    /// `unshare` refused (Docker's default seccomp profile): the lock keeps the same guarantee.
    #[test]
    fn the_lock_keeps_a_file_written_or_copied_here_from_being_busy() {
        starts_while_other_threads_fork(Mode::Lock, write_then_copy(Mode::Lock));
    }

    /// The probe agrees with what `unshare` does on this machine, and only a refusal ever gives the lock.
    #[test]
    fn the_mode_follows_whether_unshare_is_allowed() {
        if std::env::var_os("DRGNX_EXE_MODE").is_some() {
            return; // the override decides
        }
        let allowed = std::thread::scope(|s| {
            // SAFETY: CLONE_FILES alone gives the calling thread a copy of the file table
            s.spawn(|| unsafe { libc::unshare(libc::CLONE_FILES) } == 0)
                .join()
                .unwrap()
        });
        assert_eq!(
            mode(),
            if allowed {
                Mode::PrivateTable
            } else {
                Mode::Lock
            }
        );
    }
}
