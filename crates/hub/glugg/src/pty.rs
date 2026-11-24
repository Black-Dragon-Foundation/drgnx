//! The PTY and the shell on it: a new session whose controlling terminal is the PTY's other side.

use rustix::fd::{AsFd, OwnedFd};
use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
use rustix::termios::{Winsize, tcgetwinsize, tcsetwinsize};
use std::io;
use std::process::Child;

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
        let slave: OwnedFd = rustix::fs::open(
            name.as_c_str(),
            rustix::fs::OFlags::RDWR | rustix::fs::OFlags::NOCTTY | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )?;
        tcsetwinsize(&slave, size)?;
        let slave = std::sync::Arc::new(slave);
        let spec = draugr::Spec {
            program: program.into(),
            args: args.iter().map(Into::into).collect(),
            env: env.iter().map(|(k, v)| (k.into(), v.into())).collect(),
            cwd: Some(dir.into()),
            stdin_null: false,
            pass_fds: Vec::new(),
            new_session: true,
        };
        // the shell's stdio is the PTY's other side, which is also its controlling terminal
        let opts = draugr::Opts {
            controlling_tty: Some(slave.clone()),
            stdin: Some(slave.clone()),
            stdout: draugr::Redirect::To(slave.clone()),
            stderr: draugr::Redirect::To(slave),
            ..draugr::Opts::default()
        };
        let child = draugr::spawn_std(&spec, &opts)?;
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
