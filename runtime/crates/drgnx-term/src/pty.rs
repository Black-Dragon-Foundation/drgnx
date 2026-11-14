//! The PTY and the shell on it: a new session whose controlling terminal is the PTY's other side.

use rustix::fd::{AsFd, BorrowedFd, OwnedFd};
use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
use rustix::termios::{Winsize, tcgetwinsize, tcsetwinsize};
use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

/// A PTY master and the program running on it.
pub struct Pty {
    pub master: OwnedFd,
    pub child: Child,
}

/// The window size of COLS × ROWS cells of CELL px.
pub fn winsize(cols: u16, rows: u16, cell: (u32, u32)) -> Winsize {
    Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: (cell.0 * cols as u32).min(u16::MAX as u32) as u16,
        ws_ypixel: (cell.1 * rows as u32).min(u16::MAX as u32) as u16,
    }
}

impl Pty {
    /// Run PROGRAM with ARGS in DIR on a new PTY of SIZE, with exactly the environment ENV.
    pub fn spawn(
        program: &str,
        args: &[String],
        dir: &str,
        env: &[(String, String)],
        size: Winsize,
    ) -> io::Result<Pty> {
        #[cfg(not(target_os = "macos"))]
        let master = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY | OpenptFlags::CLOEXEC)?;
        // macOS's posix_openpt takes no O_CLOEXEC: the flag is set right after (no other thread forks meanwhile)
        #[cfg(target_os = "macos")]
        let master = {
            let m = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY)?;
            rustix::io::fcntl_setfd(&m, rustix::io::FdFlags::CLOEXEC)?;
            m
        };
        grantpt(&master)?;
        unlockpt(&master)?;
        let name = ptsname(&master, Vec::new())?;
        let slave: OwnedFd = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(rustix::fs::OFlags::NOCTTY.bits() as i32)
            .open(OsStr::from_bytes(name.as_bytes()))?
            .into();
        tcsetwinsize(&slave, size)?;
        let mut cmd = Command::new(program);
        cmd.args(args)
            .current_dir(dir)
            .env_clear()
            .envs(env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        // SAFETY: setsid and ioctl are async-signal-safe; stdin is the PTY's other side by now.
        unsafe {
            cmd.pre_exec(|| {
                rustix::process::setsid()?;
                rustix::process::ioctl_tiocsctty(BorrowedFd::borrow_raw(0))?;
                Ok(())
            });
        }
        let child = cmd.spawn()?;
        set_nonblocking(&master)?;
        Ok(Pty { master, child })
    }

    /// The program's new SIZE; whether it changed (the kernel sends SIGWINCH only then).
    pub fn resize(&self, size: Winsize) -> io::Result<bool> {
        let old = tcgetwinsize(&self.master)?;
        tcsetwinsize(&self.master, size)?;
        Ok((old.ws_col, old.ws_row, old.ws_xpixel, old.ws_ypixel)
            != (size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel))
    }
}

/// FD's reads and writes no longer block.
pub fn set_nonblocking(fd: impl AsFd) -> io::Result<()> {
    use rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
    let flags = fcntl_getfl(&fd)?;
    fcntl_setfl(&fd, flags | OFlags::NONBLOCK)?;
    Ok(())
}
