//! A program's clipboard read (OSC 52 `?`), asked of the editor: libghostty-vt's read callback is synchronous (the VT
//! stream waits for its reply), so the worker asks the hub on its own socket and waits here, at most [`WAIT`], for the
//! editor's answer. Every other message that arrives meanwhile is kept, whole lines, for the worker's loop to read next
//! (`Asker::take_stash`). A hub that went away, a timeout, or a "no" answer: the read is denied.

use crate::proto::{In, Out};
use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::net::RecvFlags;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

/// How long a read waits for the editor's answer.
pub const WAIT: Duration = Duration::from_secs(30);

/// The worker's side of one ask: a clone of the hub socket, and the lines that arrived while it waited.
#[derive(Debug)]
pub struct Asker {
    stream: UnixStream,
    stash: Vec<u8>,
    next: u64,
}

impl Asker {
    pub fn new(stream: UnixStream) -> Self {
        Self {
            stream,
            stash: Vec::new(),
            next: 1,
        }
    }

    /// The lines read from the hub while waiting that were not the answer: for the worker's loop, in order.
    pub fn take_stash(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.stash)
    }

    /// Ask the editor whether the program may read the clipboard (PRIMARY when `primary`), waiting at most `wait`:
    /// the text it may read, or `None` (denied, timed out, or the hub is gone).
    pub fn ask(&mut self, primary: bool, wait: Duration) -> Option<String> {
        let req = self.next;
        self.next += 1;
        let mut line = serde_json::to_vec(&Out::ClipboardRead { req, primary }).ok()?;
        line.push(b'\n');
        self.stream.write_all(&line).ok()?;
        let deadline = Instant::now() + wait;
        let mut acc: Vec<u8> = Vec::new();
        let mut buf = [0u8; 16 * 1024];
        let mut answer: Option<Option<String>> = None;
        let mut gone = false;
        while answer.is_none() && !gone {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            let t = Timespec {
                tv_sec: left.as_secs() as i64,
                tv_nsec: i64::from(left.subsec_nanos()),
            };
            let mut fds = [PollFd::new(&self.stream, PollFlags::IN)];
            match poll(&mut fds, Some(&t)) {
                Ok(0) => break,
                Ok(_) => {}
                Err(rustix::io::Errno::INTR) => continue,
                Err(_) => break,
            }
            loop {
                match rustix::net::recv(&self.stream, &mut buf, RecvFlags::DONTWAIT) {
                    Ok((0, _)) => {
                        gone = true;
                        break;
                    }
                    Ok((n, _)) => acc.extend_from_slice(&buf[..n]),
                    Err(rustix::io::Errno::AGAIN) => break,
                    Err(rustix::io::Errno::INTR) => continue,
                    Err(_) => {
                        gone = true;
                        break;
                    }
                }
            }
            // whole lines: the answer is taken, every other line (and a partial one) is kept for the loop
            let mut used = 0;
            while let Some(nl) = acc[used..].iter().position(|b| *b == b'\n') {
                let l = &acc[used..used + nl];
                match serde_json::from_slice::<In>(l) {
                    Ok(In::ClipboardReply { req: r, text }) if r == req && answer.is_none() => {
                        answer = Some(text)
                    }
                    _ => {
                        self.stash.extend_from_slice(l);
                        self.stash.push(b'\n');
                    }
                }
                used += nl + 1;
            }
            acc.drain(..used);
        }
        self.stash.extend_from_slice(&acc);
        answer.flatten()
    }
}
