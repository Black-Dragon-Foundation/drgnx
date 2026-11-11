//! The worker's one thread: a poll loop over the PTY and the hub's socket. The program's output goes into the engine
//! as it arrives; frames and backfill go out when the clock says; the hub's messages come in as lines. Nothing logged
//! here carries the program's bytes or the keys typed, only their counts.

use crate::frame::{Ms, Next};
use crate::proto::{In, Out, PROTO};
use crate::pty::Pty;
use crate::worker::Worker;
use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::net::RecvFlags;
use std::io::{self, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::ExitStatusExt;
use std::time::Instant;

/// How long a worker whose program ended waits for a hub to tell, in seconds.
const EXIT_WAIT_S: i64 = 30;

/// How the program ended: its exit code, or the signal that ended it.
pub type Exit = (Option<i32>, Option<i32>);

fn write_out(ctl: &mut UnixStream, out: Vec<Out>) -> io::Result<()> {
    if out.is_empty() {
        return Ok(());
    }
    let mut buf = Vec::new();
    for o in &out {
        serde_json::to_writer(&mut buf, o).map_err(io::Error::other)?;
        buf.push(b'\n');
    }
    tracing::trace!(messages = out.len(), bytes = buf.len(), "to hub");
    ctl.write_all(&buf)
}

/// The worker's socket at PATH (a stale one replaced), mode 0600: only this user connects, and [`ours`] checks each
/// peer as well.
pub fn listen(path: &std::path::Path) -> io::Result<UnixListener> {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::remove_file(path);
    let l = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(l)
}

/// The uid of the process at the other end of C.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(c: &UnixStream) -> io::Result<u32> {
    Ok(rustix::net::sockopt::socket_peercred(c)?.uid.as_raw())
}

/// The uid of the process at the other end of C.
#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn peer_uid(c: &UnixStream) -> io::Result<u32> {
    use std::os::fd::AsRawFd;
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: getpeereid(3) writes the two ids of a connected socket
    if unsafe { libc::getpeereid(c.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// Whether connection C is this user's: another uid's is dropped unread (the trust boundary is the uid, as for tmux).
fn ours(c: &UnixStream) -> bool {
    let me = rustix::process::geteuid().as_raw();
    match peer_uid(c) {
        Ok(uid) if uid == me => true,
        Ok(uid) => {
            tracing::warn!(uid, "a connection of another user: dropped");
            false
        }
        Err(e) => {
            tracing::warn!(error = %e, "a connection whose user does not read: dropped");
            false
        }
    }
}

/// Run WORKER on PTY until the program ends, serving the hub on CTL and on each connection LISTENER accepts (a new one
/// replaces the last: a restarted hub adopts the worker, `docs/develop/terminal.md`, "Lifetime"). The hub going away
/// never ends the program.
pub fn run(
    mut worker: Worker,
    mut pty: Pty,
    ctl: Option<UnixStream>,
    listener: Option<UnixListener>,
) -> io::Result<Exit> {
    let start = Instant::now();
    let now = || -> Ms { start.elapsed().as_millis() as Ms };
    let mut ctl = ctl;
    let mut inbuf: Vec<u8> = Vec::new();
    let shell_pid = pty.child.id();
    worker.set_shell_pid(shell_pid);
    let hello = || Out::Hello {
        proto: PROTO,
        pid: std::process::id(),
        shell_pid,
    };
    if let Some(c) = ctl.as_mut() {
        write_out(c, vec![hello()])?;
    }
    if let Some(l) = &listener {
        l.set_nonblocking(true)?;
    }
    let mut pending: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut pty_open = true;
    loop {
        // when the next frame or chunk is due
        let wait = match worker.step(now()) {
            Next::At(t) => Some(t.saturating_sub(now())),
            Next::Frame | Next::Backfill => Some(0),
            Next::Idle => None,
        };
        if let Some(c) = ctl.as_mut()
            && write_out(c, worker.take_out()).is_err()
        {
            tracing::info!("hub connection lost");
            ctl = None;
            inbuf.clear();
            worker.detach(now());
        }
        if !pty_open {
            break;
        }
        let timeout = wait.map(|ms| Timespec {
            tv_sec: (ms / 1000) as i64,
            tv_nsec: ((ms % 1000) * 1_000_000) as i64,
        });
        // while output waits behind an image's decode the PTY is not read: the kernel holds the program back
        let mut pty_events = if worker.wants_output() {
            PollFlags::IN
        } else {
            PollFlags::empty()
        };
        if !pending.is_empty() {
            pty_events |= PollFlags::OUT;
        }
        let (pty_ready, ctl_ready, new_hub, images_ready) = {
            let none = PollFlags::empty();
            let mut fds = vec![PollFd::new(&pty.master, pty_events)];
            let ci = ctl.as_ref().map(|c| {
                fds.push(PollFd::new(c, PollFlags::IN));
                fds.len() - 1
            });
            let li = listener.as_ref().map(|l| {
                fds.push(PollFd::new(l, PollFlags::IN));
                fds.len() - 1
            });
            let wi = worker.images_wake().map(|w| {
                fds.push(PollFd::new(w, PollFlags::IN));
                fds.len() - 1
            });
            match poll(&mut fds, timeout.as_ref()) {
                Ok(_) => {}
                Err(rustix::io::Errno::INTR) => continue,
                Err(e) => return Err(e.into()),
            }
            let at = |i: Option<usize>| i.map_or(none, |i| fds[i].revents());
            (
                fds[0].revents(),
                at(ci),
                !at(li).is_empty(),
                !at(wi).is_empty(),
            )
        };
        if images_ready {
            worker.images(now(), false);
        }
        if new_hub
            && let Some(l) = &listener
            && let Ok((c, _)) = l.accept()
            && ours(&c)
        {
            c.set_nonblocking(false)?;
            tracing::info!("hub connected");
            ctl = Some(c);
            inbuf.clear();
            worker.detach(now());
            write_out(ctl.as_mut().expect("just set"), vec![hello()])?;
        }
        if pty_ready.intersects(PollFlags::IN | PollFlags::HUP | PollFlags::ERR) {
            loop {
                match rustix::io::read(&pty.master, &mut buf) {
                    Ok(0) => {
                        pty_open = false;
                        break;
                    }
                    Ok(n) => {
                        tracing::trace!(bytes = n, "program output");
                        worker.output(&buf[..n], now());
                    }
                    Err(rustix::io::Errno::AGAIN) => break,
                    Err(rustix::io::Errno::INTR) => continue,
                    // EIO: the program's side closed
                    Err(_) => {
                        pty_open = false;
                        break;
                    }
                }
            }
            if !pty_open {
                // what the program wrote last: the loop's next turn sends it, then ends
                worker.flush(now());
            }
        }
        if ctl_ready.intersects(PollFlags::IN | PollFlags::HUP | PollFlags::ERR)
            && let Some(c) = ctl.as_ref()
        {
            // the socket stays blocking for writes; reads never wait
            let mut lost = false;
            loop {
                match rustix::net::recv(c, &mut buf, RecvFlags::DONTWAIT) {
                    Ok((0, _)) => {
                        lost = true;
                        break;
                    }
                    Ok((n, _)) => inbuf.extend_from_slice(&buf[..n]),
                    Err(rustix::io::Errno::AGAIN) => break,
                    Err(rustix::io::Errno::INTR) => continue,
                    Err(_) => {
                        lost = true;
                        break;
                    }
                }
            }
            let mut used = 0;
            while let Some(nl) = inbuf[used..].iter().position(|b| *b == b'\n') {
                match serde_json::from_slice::<In>(&inbuf[used..used + nl]) {
                    Ok(msg) => {
                        // the program learns the new size from the pty (SIGWINCH); the engine from the worker
                        if let In::Resize {
                            cols,
                            rows,
                            cell_px,
                            redraw,
                        } = &msg
                        {
                            match pty.resize(crate::pty::winsize(*cols, *rows, *cell_px)) {
                                // a reattach at the same size: the program redraws all the same
                                // SAFETY: a plain kill(2) of the program's process group.
                                Ok(false) if *redraw => unsafe {
                                    libc::kill(-(shell_pid as i32), libc::SIGWINCH);
                                },
                                Ok(_) => {}
                                Err(e) => tracing::warn!(error = %e, "resizing the pty"),
                            }
                        }
                        worker.handle(msg, now())
                    }
                    // the error's position only: never the message, which may hold typed text
                    Err(e) => tracing::warn!(
                        line = e.line(),
                        column = e.column(),
                        "bad message from the hub"
                    ),
                }
                used += nl + 1;
            }
            inbuf.drain(..used);
            if lost {
                tracing::info!("hub connection closed");
                ctl = None;
                inbuf.clear();
                worker.detach(now());
            }
        }
        pending.append(&mut worker.take_pty());
        if !pending.is_empty() {
            match rustix::io::write(&pty.master, &pending) {
                Ok(n) => {
                    tracing::trace!(bytes = n, "to program");
                    pending.drain(..n);
                }
                Err(rustix::io::Errno::AGAIN) | Err(rustix::io::Errno::INTR) => {}
                Err(_) => pending.clear(),
            }
        }
        if let Some(sig) = worker.take_close() {
            tracing::info!(signal = sig, "closing the program");
            // SAFETY: a plain kill(2) of the program's process group (it leads its own session).
            unsafe { libc::kill(-(shell_pid as i32), sig) };
        }
    }
    let status = pty.child.wait()?;
    let exit = (status.code(), status.signal());
    tracing::info!(code = ?exit.0, signal = ?exit.1, "program ended");
    // a program that ended before any hub connected (or while none was): the exit waits for the next one, a while
    if ctl.is_none()
        && let Some(l) = &listener
    {
        let mut fds = [PollFd::new(l, PollFlags::IN)];
        let t = Timespec {
            tv_sec: EXIT_WAIT_S,
            tv_nsec: 0,
        };
        if matches!(poll(&mut fds, Some(&t)), Ok(n) if n > 0)
            && let Ok((mut c, _)) = l.accept()
            && ours(&c)
        {
            c.set_nonblocking(false)?;
            let _ = write_out(&mut c, vec![hello()]);
            ctl = Some(c);
        }
    }
    if let Some(c) = ctl.as_mut() {
        let _ = write_out(
            c,
            vec![Out::Exit {
                code: exit.0,
                signal: exit.1,
            }],
        );
    }
    Ok(exit)
}
