//! One connection's queue and its read-or-closed choice, without I/O (docs/develop/hub.md, "One connection"): what the
//! shell's events do to the queue of lines for the client, whether a line read is served, and when the writer ends.
//! The shell ([`super::Outbox`], the writer task and the reader) does the I/O and feeds every event through
//! [`ConnCore::step`].
//!
//! The edges the shell keeps (each tested in the shell's tests): a `Written` follows the `Push` of its line;
//! `ClientEof` is the last read event; the writer reports at most one of `WriteRefused` and `WriteStuck`, and ends.

use super::MAX_QUEUED;
use std::collections::VecDeque;

/// What happens to a connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ConnEvent {
    /// The hub queues a line of LEN bytes for the client.
    Push { len: usize },
    /// The hub closes the connection (a malformed line, the writer's end).
    Close,
    /// The client sent its end of file.
    ClientEof,
    /// Reading the client's socket failed.
    ReadError,
    /// A complete line was read from the client.
    LineRead,
    /// The line at the front of the queue, LEN bytes, was written.
    Written { len: usize },
    /// The client's socket refused a write: the client left.
    WriteRefused,
    /// A write made no progress for `STUCK_AFTER`.
    WriteStuck,
    /// `mcp/attach` was answered: the connection's next bytes are MCP's, never hub lines.
    Attach,
}

/// What the shell does about a step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ConnEffect {
    /// The pushed line joins the queue.
    Queue,
    /// The pushed line is refused: the connection is closed or finishing, or closed now for going over the limit.
    Refuse,
    /// What was queued is dropped.
    Drop,
    /// The connection's first close: logged, with the shell's reason.
    Log,
    /// The line read is served.
    Serve,
    /// The line read is not: reading has stopped.
    Skip,
    /// The line written leaves the queue.
    Pop,
}

/// See the module.
#[derive(Debug, Default)]
pub(crate) struct ConnCore {
    /// The queued lines' lengths, oldest first.
    queue: VecDeque<usize>,
    bytes: usize,
    /// Nothing more is queued: the writer ends once the queue is written (EOF, or the connection became MCP's).
    finishing: bool,
    /// The queue is dropped and takes no more (a close, a refused or stuck write).
    discarded: bool,
    /// Lines are no longer read (a close, a read error, a stuck write): a refused write is not one.
    closed: bool,
    eof: bool,
    attached: bool,
}

impl ConnCore {
    pub(crate) fn new() -> ConnCore {
        ConnCore::default()
    }

    pub(crate) fn step(&mut self, ev: ConnEvent) -> Vec<ConnEffect> {
        use ConnEffect as E;
        match ev {
            ConnEvent::Push { len } => {
                if self.discarded || self.finishing {
                    return vec![E::Refuse];
                }
                if self.bytes + len > MAX_QUEUED {
                    let mut e = self.close();
                    e.push(E::Refuse);
                    return e;
                }
                self.queue.push_back(len);
                self.bytes += len;
                vec![E::Queue]
            }
            ConnEvent::Close | ConnEvent::ReadError | ConnEvent::WriteStuck => self.close(),
            // the client left: nothing more is written, but what it sent before is still read and served
            ConnEvent::WriteRefused => self.discard(),
            ConnEvent::ClientEof => {
                self.eof = true;
                self.finishing = true;
                Vec::new()
            }
            ConnEvent::Attach => {
                self.attached = true;
                self.finishing = true;
                Vec::new()
            }
            ConnEvent::LineRead => vec![if self.reading() { E::Serve } else { E::Skip }],
            ConnEvent::Written { len } => {
                if self.discarded || self.queue.front() != Some(&len) {
                    return Vec::new();
                }
                self.queue.pop_front();
                self.bytes -= len;
                vec![E::Pop]
            }
        }
    }

    fn close(&mut self) -> Vec<ConnEffect> {
        self.closed = true;
        self.discard()
    }

    fn discard(&mut self) -> Vec<ConnEffect> {
        if self.discarded {
            return Vec::new();
        }
        self.discarded = true;
        self.queue.clear();
        self.bytes = 0;
        vec![ConnEffect::Drop, ConnEffect::Log]
    }

    /// Are the client's lines read and served?  The reader's choice between its socket and the close.
    pub(crate) fn reading(&self) -> bool {
        !self.closed && !self.eof && !self.attached
    }

    /// Was the connection closed (not by the client's EOF or a refused write)?  The reader stops at once.
    pub(crate) fn closed(&self) -> bool {
        self.closed
    }

    /// Does the writer go on?  It ends when the queue is dropped, or when finishing with nothing left to write.
    pub(crate) fn writing(&self) -> bool {
        !self.discarded && (!self.finishing || !self.queue.is_empty())
    }

    pub(crate) fn queued_bytes(&self) -> usize {
        self.bytes
    }

    /// Was everything written, the queue finished and never dropped?  Then the write half is handed on (`mcp/attach`).
    pub(crate) fn whole(&self) -> bool {
        !self.discarded && self.finishing && self.queue.is_empty()
    }
}

#[cfg(test)]
mod tests;
