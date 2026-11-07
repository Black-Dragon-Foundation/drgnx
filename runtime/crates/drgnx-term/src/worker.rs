//! One terminal: the engine, the editor's rows, the frame clock and the style table, driven by the loop (or a test)
//! with the time passed in. Nothing here touches the PTY or the socket: the bytes for the program and the messages for
//! the hub queue until the loop takes them.

use crate::engine::{Effect, Engine};
use crate::frame::{Clock, Ms, Next};
use crate::keys;
use crate::proto::{In, Out};
use crate::rows::{Key, RowId, Tracker};
use crate::style::{Cell, StyleTable, build};
use drgnx_rows::{Op, Patch, Row, TermMeta};
use ghostty_vt_sys::bindings::*;
use std::collections::HashMap;

/// The largest backfill patch, in bytes of row JSON.
pub const BACKFILL_MAX_BYTES: usize = 40_000;
/// The most rows one backfill chunk reads.
const BACKFILL_MAX_ROWS: usize = 1024;

/// How a terminal starts.
#[derive(Clone, Debug)]
pub struct Opts {
    pub cols: u16,
    pub rows: u16,
    pub cell_px: (u32, u32),
    /// The rows above the screen the editor's buffer keeps (`drgnx-term-scrollback-lines`).
    pub window: usize,
    /// The engine's scrollback, at least the window.
    pub scrollback: usize,
    /// The engine's scrollback in bytes, a ceiling over the lines (`drgnx-term-scrollback-bytes`).
    pub scrollback_bytes: usize,
    pub clipboard_write: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            cols: 80,
            rows: 24,
            cell_px: (0, 0),
            window: 10_000,
            scrollback: 10_000,
            scrollback_bytes: 64 << 20,
            clipboard_write: true,
        }
    }
}

#[derive(Clone, Debug)]
struct Attach {
    view: String,
    class: String,
    hub: u64,
    env_epoch: u64,
}

pub struct Worker {
    engine: Engine,
    tracker: Tracker,
    clock: Clock,
    styles: StyleTable,
    attach: Option<Attach>,
    version: u64,
    reset_due: bool,
    alt: bool,
    backfill_due: bool,
    /// The screen rows last sent, and where each column starts in them (for the cursor).
    sent: HashMap<Key, (Row, Vec<u32>)>,
    meta: Option<TermMeta>,
    window: usize,
    scrollback_bytes: usize,
    out: Vec<Out>,
    pty: Vec<u8>,
    closing: Option<i32>,
    marks: crate::child::Marks,
    shell_pid: u32,
}

impl Worker {
    pub fn new(opts: &Opts) -> Result<Worker, String> {
        let mut engine = Engine::new(
            opts.cols,
            opts.rows,
            opts.cell_px,
            opts.scrollback.max(opts.window),
            opts.scrollback_bytes,
        )?;
        engine.sink().clipboard_write = opts.clipboard_write;
        Ok(Worker {
            engine,
            tracker: Tracker::new(opts.window),
            clock: Clock::default(),
            styles: StyleTable::default(),
            attach: None,
            version: 0,
            reset_due: true,
            alt: false,
            backfill_due: false,
            sent: HashMap::new(),
            meta: None,
            window: opts.window,
            scrollback_bytes: opts.scrollback_bytes,
            out: Vec::new(),
            pty: Vec::new(),
            closing: None,
            marks: crate::child::Marks::default(),
            shell_pid: 0,
        })
    }

    /// The program's pid (the loop sets it once the program runs).
    pub fn set_shell_pid(&mut self, pid: u32) {
        self.shell_pid = pid;
    }

    pub fn engine(&mut self) -> &mut Engine {
        &mut self.engine
    }

    /// The messages for the hub, in order.
    pub fn take_out(&mut self) -> Vec<Out> {
        std::mem::take(&mut self.out)
    }

    /// The bytes for the program, in order.
    pub fn take_pty(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.pty)
    }

    /// The signal the hub asked to end the program with, once.
    pub fn take_close(&mut self) -> Option<i32> {
        self.closing.take()
    }

    /// The program's output arrived at NOW.
    pub fn output(&mut self, bytes: &[u8], now: Ms) {
        self.engine.write(bytes);
        self.clock.output(now);
        self.effects(now);
    }

    fn effects(&mut self, now: Ms) {
        let sink = self.engine.sink();
        self.pty.append(&mut sink.pty);
        let effects = std::mem::take(&mut sink.effects);
        for e in effects {
            match e {
                Effect::Hold(h) => self.clock.hold(h, now),
                Effect::Bell => self.out.push(Out::Bell),
                Effect::Title => {
                    let title = self.engine.title();
                    self.clock.touch();
                    self.out.push(Out::Title { title });
                }
                Effect::Pwd => {
                    let cwd = self.engine.pwd();
                    self.out.push(Out::Cwd { cwd });
                }
                Effect::Clipboard {
                    primary,
                    mime,
                    data,
                } => self.out.push(Out::ClipboardWrite {
                    primary,
                    mime,
                    data,
                }),
                Effect::Notify { title, body } => self.out.push(Out::Notify { title, body }),
                Effect::Progress { state, value } => self.out.push(Out::Progress { state, value }),
                Effect::Prompt { kind, exit } => {
                    self.marks.mark(kind);
                    self.out.push(Out::Prompt { kind, exit });
                }
            }
        }
    }

    /// A message from the hub at NOW.
    pub fn handle(&mut self, msg: In, now: Ms) {
        match msg {
            In::Attach {
                view,
                class,
                hub,
                env_epoch,
            } => {
                self.attach = Some(Attach {
                    view,
                    class,
                    hub,
                    env_epoch,
                });
                self.resync();
            }
            In::Env { env_epoch } => {
                if let Some(a) = &mut self.attach {
                    a.env_epoch = env_epoch;
                }
            }
            In::Key {
                key,
                mods,
                text,
                unshifted,
            } => self.key(&key, keys::mods(&mods), &text, unshifted, now),
            In::Text { text } => {
                self.pty.extend_from_slice(text.as_bytes());
                self.clock.key(now);
            }
            In::Paste { text } => {
                let b = self.engine.encode_paste(&text);
                self.pty.extend_from_slice(&b);
                self.clock.key(now);
            }
            In::Focus { gained } => {
                let b = self.engine.encode_focus(gained);
                self.pty.extend_from_slice(&b);
            }
            In::Mouse {
                kind,
                button,
                col,
                row,
                mods,
            } => {
                let action = match kind.as_str() {
                    "release" => GHOSTTY_MOUSE_ACTION_RELEASE,
                    "motion" => GHOSTTY_MOUSE_ACTION_MOTION,
                    _ => GHOSTTY_MOUSE_ACTION_PRESS,
                };
                let b = self.mouse(action, button, col, row, keys::mods(&mods));
                self.pty.extend_from_slice(&b);
            }
            In::Resize {
                cols,
                rows,
                cell_px,
            } => self.resize(cols, rows, cell_px),
            In::Ack { version } => self.ack(version),
            In::Resync => self.resync(),
            In::Config { config } => {
                for (name, value) in config {
                    self.config(&name, &value);
                }
            }
            In::Status { req } => self.out.push(Out::Status {
                req,
                running: self.marks.running(self.shell_pid),
                cwd: self.engine.pwd(),
                title: self.engine.title(),
                shell_pid: self.shell_pid,
            }),
            In::Close { signal } => self.closing = Some(signal.unwrap_or(1)),
        }
    }

    /// A key press: its bytes go to the program, and the echo is drawn at once.
    pub fn key(&mut self, name: &str, mods: u16, text: &str, unshifted: u32, now: Ms) {
        let (code, base) = keys::code(name);
        let unshifted = if unshifted != 0 { unshifted } else { base };
        // without the kitty flags, ctrl+i, ctrl+m and ctrl+[ are the C0 byte (tab, return, escape) as in xterm; the
        // encoder would send them as CSI u (fixterms), which shells do not read
        if self.engine.kitty_flags() == 0
            && text.is_empty()
            && mods & !GHOSTTY_MODS_ALT == GHOSTTY_MODS_CTRL
            && let Some(c @ ('i' | 'm' | '[')) = char::from_u32(unshifted)
        {
            if mods & GHOSTTY_MODS_ALT != 0 {
                self.pty.push(0x1b);
            }
            self.pty.push((c as u8) & 0x1f);
            self.clock.key(now);
            return;
        }
        let text = text.to_owned();
        let b = self.engine.encode_key(code, mods, &text, unshifted);
        self.pty.extend_from_slice(&b);
        self.clock.key(now);
    }

    /// A mouse event's bytes (none unless the program tracks the mouse).
    pub fn mouse(&mut self, action: i32, button: i32, col: u32, row: u32, mods: u16) -> Vec<u8> {
        if !self.engine.mouse_tracking() {
            return Vec::new();
        }
        self.engine.encode_mouse(action, button, col, row, mods)
    }

    /// A new size: the lines rewrap, so the next patch is a reset.
    pub fn resize(&mut self, cols: u16, rows: u16, cell_px: (u32, u32)) {
        let _ = self.engine.resize(cols, rows, cell_px);
        self.reset_due = true;
        self.clock.touch();
    }

    /// No hub draws this terminal (it went away, or a new one connected and has not attached yet): nothing is sent
    /// until the next attach, which starts with a reset.
    pub fn detach(&mut self) {
        self.attach = None;
        self.reset_due = true;
        self.clock.acked();
    }

    pub fn ack(&mut self, version: u64) {
        if version == self.version {
            self.clock.acked();
        }
    }

    /// The editor lost track (or attached): forget what is in flight, send a reset.
    pub fn resync(&mut self) {
        self.reset_due = true;
        self.clock.acked();
        self.clock.touch();
    }

    pub fn config(&mut self, name: &str, value: &serde_json::Value) {
        match name {
            "scrollback-lines" => {
                if let Some(n) = value.as_u64() {
                    self.window = n as usize;
                    self.engine
                        .set_scrollback(self.window, self.scrollback_bytes);
                    self.tracker.set_above_max(self.window);
                    self.backfill_due = true;
                    self.clock.touch();
                }
            }
            "scrollback-bytes" => {
                if let Some(n) = value.as_u64() {
                    self.scrollback_bytes = n as usize;
                    self.engine
                        .set_scrollback(self.window, self.scrollback_bytes);
                }
            }
            "clipboard-write" => {
                self.engine.sink().clipboard_write = value.as_bool().unwrap_or(false)
            }
            _ => {}
        }
    }

    pub fn in_flight(&self) -> bool {
        self.clock.in_flight()
    }

    /// What to do next at NOW.
    pub fn next(&self, now: Ms) -> Next {
        if self.attach.is_none() {
            return Next::Idle;
        }
        self.clock.next(now, self.backfill_due)
    }

    /// Draw what changed now, whatever the clock says (the program ended).
    pub fn flush(&mut self, now: Ms) {
        if self.clock.dirty() {
            self.frame(now);
        }
    }

    /// Do what is due at NOW; returns what comes after.
    pub fn step(&mut self, now: Ms) -> Next {
        match self.next(now) {
            Next::Frame => self.frame(now),
            Next::Backfill => self.backfill(),
            _ => {}
        }
        self.next(now)
    }

    fn send(&mut self, reset: bool, ops: Vec<Op>, term: Option<TermMeta>) {
        let Some(a) = &self.attach else { return };
        let base = if reset { 0 } else { self.version };
        self.version += 1;
        let patch = Patch {
            view: a.view.clone(),
            class: a.class.clone(),
            hub: a.hub,
            base,
            version: self.version,
            env_epoch: a.env_epoch,
            ops,
            images: Vec::new(),
            styles: self.styles.take(reset),
            term,
        };
        self.out.push(Out::Patch {
            patch: Box::new(patch),
        });
    }

    fn build(&mut self, key: &str, cells: &[Cell]) -> Row {
        let built = build(key, cells, self.engine.size().2.0, &mut self.styles);
        self.sent
            .insert(key.to_owned(), (built.row.clone(), built.cols));
        built.row
    }

    /// Draw a frame: the screen's changed rows (a reset when due), the cursor and the screen's state.
    fn frame(&mut self, now: Ms) {
        if self.attach.is_none() {
            self.clock.drew(now, false);
            return;
        }
        // a screen's height above it too: the rows that just scrolled off, still readable
        let rows_n = self.engine.size().1;
        self.engine.update(rows_n);
        let alt = self.engine.alt_screen();
        let reset = self.reset_due || alt != self.alt;
        let mut screen: Vec<(RowId, bool)> = Vec::new();
        let mut cells: HashMap<RowId, Vec<Cell>> = HashMap::new();
        {
            let tracker = &self.tracker;
            let was = |id: &RowId| tracker.screen().iter().any(|(s, _)| s == id);
            self.engine.rows(|id, dirty, y, r| {
                if y < 0 {
                    if !reset && was(&id) {
                        cells.insert(id, r.cells());
                    }
                    return;
                }
                screen.push((id, dirty));
                if reset || dirty || !was(&id) {
                    cells.insert(id, r.cells());
                }
            });
        }
        let plan = if reset {
            None
        } else {
            self.tracker.frame(&screen, !alt)
        };
        let mut ops = Vec::new();
        let reset = match plan {
            None => {
                self.styles.clear();
                self.sent.clear();
                let ids: Vec<RowId> = screen.iter().map(|(id, _)| *id).collect();
                let keyed = self.tracker.reset(&ids);
                let rows: Vec<Row> = keyed
                    .iter()
                    .map(|(id, k)| {
                        let c = cells.remove(id).unwrap_or_default();
                        self.build(k, &c)
                    })
                    .collect();
                ops.push(Op::Reset(rows));
                self.backfill_due = !alt;
                true
            }
            Some(plan) => {
                for k in &plan.remove {
                    self.sent.remove(k);
                }
                if !plan.remove.is_empty() {
                    ops.push(Op::Remove(plan.remove.clone()));
                }
                // a row that scrolled off is replaced when it changed since it was sent; one scrolled past the rows
                // read (a flood) went stale unseen: it leaves the buffer and the backfill brings it back
                let mut stale = Vec::new();
                let mut changed = Vec::new();
                for (id, k) in &plan.scrolled {
                    match cells.remove(id) {
                        Some(c) => {
                            let before = self.sent.get(k).map(|(r, _)| r.clone());
                            let row = self.build(k, &c);
                            if before.as_ref() != Some(&row) {
                                changed.push(row);
                            }
                        }
                        None => stale.push(k.clone()),
                    }
                }
                for (id, k) in &plan.replace {
                    let Some(c) = cells.remove(id) else { continue };
                    let before = self.sent.get(k).map(|(r, _)| r.clone());
                    let row = self.build(k, &c);
                    if before.as_ref() != Some(&row) {
                        changed.push(row);
                    }
                }
                if !changed.is_empty() {
                    ops.push(Op::Replace(changed));
                }
                for (after, run) in &plan.insert {
                    let rows: Vec<Row> = run
                        .iter()
                        .map(|(id, k)| {
                            let c = cells.remove(id).unwrap_or_default();
                            self.build(k, &c)
                        })
                        .collect();
                    ops.push(Op::Insert {
                        after: after.clone(),
                        rows,
                    });
                }
                let mut gone = self.tracker.take_trimmed();
                gone.extend(self.tracker.forget(&stale));
                if !gone.is_empty() {
                    ops.push(Op::Remove(gone));
                }
                if !plan.insert.is_empty() && !alt {
                    self.backfill_due = true;
                }
                // rows that scrolled off the screen are no longer the cursor's: drop their columns
                let on: std::collections::HashSet<&Key> =
                    self.tracker.screen().iter().map(|(_, k)| k).collect();
                self.sent.retain(|k, _| on.contains(k));
                false
            }
        };
        self.alt = alt;
        self.reset_due = false;
        self.engine.clean();
        let meta = self.meta();
        let term = (reset || self.meta.as_ref() != Some(&meta)).then(|| meta.clone());
        self.meta = Some(meta);
        let sent = reset || !ops.is_empty() || term.is_some();
        if sent {
            self.send(reset, ops, term);
        }
        self.clock.drew(now, sent);
    }

    fn meta(&self) -> TermMeta {
        let c = self.engine.cursor();
        let screen = self.tracker.screen();
        let (key, col) = match c.at {
            Some((x, y)) if (y as usize) < screen.len() => {
                let key = screen[y as usize].1.clone();
                let col = match self.sent.get(&key) {
                    Some((row, cols)) => match cols.get(x as usize) {
                        Some(p) => *p,
                        None => row.text.chars().count() as u32 + (x as u32 - cols.len() as u32),
                    },
                    None => x as u32,
                };
                (key, col)
            }
            _ => (String::new(), 0),
        };
        TermMeta {
            cursor: (key, col, c.shape, c.visible && c.at.is_some()),
            alt_screen: self.alt,
            mouse_tracking: self.engine.mouse_tracking(),
            title: self.engine.title(),
        }
    }

    /// Send the next chunk of rows above the screen the editor lacks: the newest gap first, at most
    /// `BACKFILL_MAX_BYTES`, inserted after the row the editor holds above it.
    fn backfill(&mut self) {
        let over = self.window.min(u16::MAX as usize) as u16;
        if over == 0 || self.alt {
            self.backfill_due = false;
            return;
        }
        self.engine.update(over);
        let mut hist: Vec<RowId> = Vec::new();
        self.engine.rows(|id, _, y, _| {
            if y < 0 {
                hist.push(id);
            }
        });
        let Some(top) = (0..hist.len())
            .rev()
            .find(|&i| !self.tracker.held(&hist[i]))
        else {
            self.backfill_due = false;
            return;
        };
        let below = hist.get(top + 1).copied();
        let mut low = top;
        while low > 0 && top - low + 1 < BACKFILL_MAX_ROWS && !self.tracker.held(&hist[low - 1]) {
            low -= 1;
        }
        // read the gap's rows (top first), then keep the newest that fit
        let mut read: Vec<(RowId, Vec<Cell>)> = Vec::new();
        let mut i = 0usize;
        self.engine.rows(|id, _, y, r| {
            if y < 0 {
                if i >= low && i <= top {
                    read.push((id, r.cells()));
                }
                i += 1;
            }
        });
        let mut bytes = 0usize;
        let mut chunk: Vec<(RowId, Row)> = Vec::new();
        let px = self.engine.size().2.0;
        for (id, cells) in read.iter().rev() {
            let row = build("", cells, px, &mut self.styles).row;
            let n = serde_json::to_vec(&row).map_or(0, |v| v.len()) + 16;
            if !chunk.is_empty() && bytes + n > BACKFILL_MAX_BYTES {
                break;
            }
            bytes += n;
            chunk.push((*id, row));
        }
        chunk.reverse();
        let anchor = self.tracker.anchor_above(below.as_ref());
        let ids: Vec<RowId> = chunk.iter().map(|(id, _)| *id).collect();
        let keyed = self.tracker.backfilled(anchor.as_ref(), &ids);
        let rows: Vec<Row> = chunk
            .into_iter()
            .zip(keyed)
            .map(|((_, mut row), (_, key))| {
                row.key = key;
                row
            })
            .collect();
        // the insert first: the window may drop the anchor itself
        let mut ops = vec![Op::Insert {
            after: anchor,
            rows,
        }];
        let gone = self.tracker.take_trimmed();
        if !gone.is_empty() {
            ops.push(Op::Remove(gone));
        }
        self.send(false, ops, None);
        self.clock.backfilled();
    }
}
