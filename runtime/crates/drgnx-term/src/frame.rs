//! When the worker draws (docs/develop/terminal.md, "The worker"). Pure: the caller passes the time in milliseconds.
//!
//! - A frame goes **at once** while a key arrived in the last 50 ms (the echo), else at most one per 16 ms while output
//!   flows.
//! - While the program holds output (mode 2026, synchronized output) the frame waits until it lets go, at most 150 ms.
//! - At most one patch is in flight: nothing is drawn until the editor acknowledges it (`view/ack`); dirtiness
//!   accumulates in the engine meanwhile.
//! - While output flows the patches carry the screen only; after 100 ms without output the rows that scrolled past
//!   unseen are backfilled, newest first.

/// Milliseconds on the worker's monotonic clock.
pub type Ms = u64;

pub const ECHO_MS: Ms = 50;
pub const FRAME_MS: Ms = 16;
pub const HOLD_MAX_MS: Ms = 150;
pub const IDLE_MS: Ms = 100;

/// What to do next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Next {
    /// Draw a frame now.
    Frame,
    /// Send the next backfill chunk now.
    Backfill,
    /// Nothing until this time (or an input).
    At(Ms),
    /// Nothing until an input.
    Idle,
}

#[derive(Clone, Debug, Default)]
pub struct Clock {
    last_key: Option<Ms>,
    last_output: Option<Ms>,
    last_frame: Option<Ms>,
    hold_since: Option<Ms>,
    dirty: bool,
    in_flight: bool,
}

impl Clock {
    /// A key went to the program at NOW.
    pub fn key(&mut self, now: Ms) {
        self.last_key = Some(now);
    }

    /// Output arrived at NOW: the screen may have changed.
    pub fn output(&mut self, now: Ms) {
        self.last_output = Some(now);
        self.dirty = true;
    }

    /// Something besides output changed what to draw (a resize, a resync, an attach).
    pub fn touch(&mut self) {
        self.dirty = true;
    }

    /// The program holds (true) or releases (false) its output (mode 2026), at NOW.
    pub fn hold(&mut self, held: bool, now: Ms) {
        self.hold_since = if held {
            self.hold_since.or(Some(now))
        } else {
            None
        };
    }

    /// A frame was drawn at NOW; SENT: it made a patch, which is now in flight.
    pub fn drew(&mut self, now: Ms, sent: bool) {
        self.last_frame = Some(now);
        self.dirty = false;
        self.in_flight |= sent;
    }

    /// A backfill chunk went (in flight).
    pub fn backfilled(&mut self) {
        self.in_flight = true;
    }

    /// The editor acknowledged the patch in flight (or the hub reset the stream: a resync, a new hub).
    pub fn acked(&mut self) {
        self.in_flight = false;
    }

    pub fn in_flight(&self) -> bool {
        self.in_flight
    }

    pub fn dirty(&self) -> bool {
        self.dirty
    }

    /// Whether output has been quiet for `IDLE_MS` at NOW.
    pub fn idle(&self, now: Ms) -> bool {
        self.last_output
            .is_none_or(|t| now.saturating_sub(t) >= IDLE_MS)
    }

    /// What to do at NOW; BACKFILL: rows wait to be backfilled.
    pub fn next(&self, now: Ms, backfill: bool) -> Next {
        if self.in_flight {
            return Next::Idle;
        }
        if self.dirty {
            if let Some(h) = self.hold_since {
                let until = h + HOLD_MAX_MS;
                if now < until {
                    return Next::At(until);
                }
            }
            if self
                .last_key
                .is_some_and(|k| now.saturating_sub(k) <= ECHO_MS)
            {
                return Next::Frame;
            }
            return match self.last_frame {
                Some(f) if now < f + FRAME_MS => Next::At(f + FRAME_MS),
                _ => Next::Frame,
            };
        }
        if backfill {
            return match self.last_output {
                Some(t) if now < t + IDLE_MS => Next::At(t + IDLE_MS),
                _ => Next::Backfill,
            };
        }
        Next::Idle
    }
}
