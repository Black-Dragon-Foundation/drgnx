//! Files the hub writes and then runs.
//!
//! On Linux, `execve` of a file that any process holds open for writing fails with ETXTBSY.  A child forked by
//! another thread copies the hub's file table, the write descriptor included, and keeps it until its own `exec`
//! closes it: so a file written here and run at once can fail to start.  A rename keeps the same file, so it does
//! not help.  [`private_fds`] does the writing on a thread with its own file table (`unshare(CLONE_FILES)`), which
//! no other thread's fork copies.  That table starts as a copy of the process's, so the thread closes all but 0, 1
//! and 2 first: otherwise a pipe or socket another thread closes would not end until the writing does.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

/// F's result, F run with descriptors no other thread's fork can copy: on Linux on a thread of its own with its
/// own file table (an error if it can't have one), which starts with only 0, 1 and 2: F opens what it uses; elsewhere
/// (no ETXTBSY on exec) here.  A descriptor F leaves open is closed when the thread ends.
pub fn private_fds<T: Send>(f: impl FnOnce() -> T + Send) -> std::io::Result<T> {
    #[cfg(target_os = "linux")]
    {
        std::thread::scope(|s| {
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
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(f())
    }
}

/// PATH made (or replaced) with CONTENTS, mode 0755, its write descriptor never in a table another fork copies.
pub fn write_executable(path: &Path, contents: impl AsRef<[u8]>) -> std::io::Result<()> {
    let contents = contents.as_ref();
    private_fds(|| {
        let _ = std::fs::remove_file(path);
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(path)?;
        f.write_all(contents)
    })?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// The private table starts with none of the process's descriptors above 2 (a pipe another thread closes while F
    /// runs ends at once); the process keeps its own.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_private_table_holds_none_of_the_process_descriptors() {
        use std::os::fd::AsRawFd;
        let file = std::fs::File::open("/dev/null").unwrap();
        let fd = file.as_raw_fd();
        // SAFETY: F_GETFD only reads the descriptor's flags
        let open = move || unsafe { libc::fcntl(fd, libc::F_GETFD) } != -1;
        assert!(
            !private_fds(open).unwrap(),
            "descriptor {fd} is open in the private table"
        );
        assert!(open(), "descriptor {fd} is still open here");
    }

    #[test]
    fn an_executable_written_here_starts_while_other_threads_fork() {
        let d = tempfile::tempdir().unwrap();
        let stop = AtomicBool::new(false);
        std::thread::scope(|s| {
            for _ in 0..4 {
                s.spawn(|| {
                    while !stop.load(Ordering::Relaxed) {
                        let _ = std::process::Command::new("/bin/true").status();
                    }
                });
            }
            let mut busy = 0;
            for i in 0..300 {
                let p = d.path().join(format!("x{i}"));
                write_executable(&p, b"#!/bin/sh\nexit 0\n").unwrap();
                match std::process::Command::new(&p).status() {
                    Ok(st) => assert!(st.success(), "{st}"),
                    Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => busy += 1,
                    Err(e) => panic!("{}: {e}", p.display()),
                }
            }
            stop.store(true, Ordering::Relaxed);
            assert_eq!(busy, 0, "{busy} of 300 failed to start: ETXTBSY");
        });
    }
}
