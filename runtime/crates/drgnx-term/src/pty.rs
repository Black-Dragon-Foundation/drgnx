//! The PTY and the shell on it: a new session whose controlling terminal is the PTY's other side.

use rustix::fd::{AsFd, BorrowedFd, OwnedFd};
use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
use rustix::termios::{Winsize, tcsetwinsize};
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
        let master = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY | OpenptFlags::CLOEXEC)?;
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

    pub fn resize(&self, size: Winsize) -> io::Result<()> {
        tcsetwinsize(&self.master, size)?;
        Ok(())
    }
}

/// FD's reads and writes no longer block.
pub fn set_nonblocking(fd: impl AsFd) -> io::Result<()> {
    use rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
    let flags = fcntl_getfl(&fd)?;
    fcntl_setfl(&fd, flags | OFlags::NONBLOCK)?;
    Ok(())
}
