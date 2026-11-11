//! One terminal: the engine, the editor's rows, the frame clock and the style table, driven by the loop (or a test)
//! with the time passed in. Nothing here touches the PTY or the socket: the bytes for the program and the messages for
//! the hub queue until the loop takes them.

use crate::engine::{Effect, Engine};
use crate::frame::{Clock, Ms, Next};
use crate::gallery::{Gallery, IMAGE_PROP, Slice};
use crate::keys;
use crate::proto::{In, KeyAction, Out};
use crate::rows::{Key, RowId, Tracker};
use crate::style::{Cell, StyleTable, build};
use drgnx_rows::{Op, Patch, Row, TermMeta};
use ghostty_vt_sys::bindings::*;
use std::collections::HashMap;

/// The largest backfill patch, in bytes of row JSON.
pub const BACKFILL_MAX_BYTES: usize = 40_000;
/// The most rows one backfill chunk reads.
const BACKFILL_MAX_ROWS: usize = 1024;
/// The fewest lines the engine keeps, whatever the window: history above the window stays readable for search and
/// copy (the bytes setting is the ceiling).
pub const ENGINE_LINES_MIN: usize = 10_000;
/// The most prompt rows remembered for `scroll` by prompts.
const PROMPTS_MAX: usize = 4096;
/// The kitty keyboard protocol's "report event types" flag: repeats and releases reach the program.
const KITTY_REPORT_EVENTS: u8 = 2;
/// How long a terminal no editor draws keeps its program before it ends it (`detached-keep`, 24 hours).
const DETACHED_KEEP_DEFAULT: Ms = 24 * 3_600_000;

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
    /// Where image canvases are written (none: images are kept but not drawn).
    pub img_dir: Option<std::path::PathBuf>,
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
            img_dir: None,
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
    /// A shell prompt (OSC 133 A) started since the last frame: the cursor's row is a prompt row.
    prompt_due: bool,
    /// The keys of prompt rows, oldest first.
    prompts: std::collections::VecDeque<Key>,
    /// The version of the view's model (Find's matches) last sent, and that model as a reset (none: no search since
    /// the view was attached).
    model_version: u64,
    model: Option<serde_json::Value>,
    /// Since when no editor draws this terminal (none: one does), and how long it may stay so before it ends its
    /// program (`detached-keep`; none: forever).
    alone_since: Option<Ms>,
    keep: Option<Ms>,
    gallery: Gallery,
}

impl Worker {
    pub fn new(opts: &Opts) -> Result<Worker, String> {
        let mut engine = Engine::new(
            opts.cols,
            opts.rows,
            opts.cell_px,
            opts.scrollback.max(opts.window).max(ENGINE_LINES_MIN),
            opts.scrollback_bytes,
        )?;
        engine.sink().clipboard_write = opts.clipboard_write;
        let mut gallery = Gallery::new(opts.img_dir.clone());
        gallery.apply(&mut engine);
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
            prompt_due: false,
            prompts: std::collections::VecDeque::new(),
            model_version: 0,
            model: None,
            // a new worker waits for its first attach like a detached one
            alone_since: Some(0),
            keep: Some(DETACHED_KEEP_DEFAULT),
            gallery,
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
        self.gallery.output(bytes, &mut self.engine);
        self.clock.output(now);
        self.effects(now);
    }

    /// The image helper's socket: readable when decoded images or canvases are ready (`images`).
    pub fn images_wake(&self) -> Option<&std::os::unix::net::UnixStream> {
        self.gallery.wake()
    }

    /// Whether the loop should read the program's output (not while output waits behind an image's decode).
    pub fn wants_output(&self) -> bool {
        self.gallery.wants_output()
    }

    /// Take the image helper's finished work at NOW (BLOCK: wait for the next result, for tests).
    pub fn images(&mut self, now: Ms, block: bool) {
        if self.gallery.collect(&mut self.engine, block) {
            self.clock.output(now);
            self.effects(now);
        }
    }

    /// Whether the image helper has work out.
    pub fn images_busy(&self) -> bool {
        self.gallery.busy()
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
                    if kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START {
                        self.prompt_due = true;
                        self.clock.touch();
                    }
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
                // a new editor's replica: its model starts again
                self.model_version = 0;
                self.model = None;
                self.alone_since = None;
                self.resync();
            }
            In::Detach => self.detach(now),
            In::Visible { visible } => {
                self.gallery.visible = visible;
                if visible {
                    self.clock.touch();
                }
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
                action,
            } => self.key(&key, keys::mods(&mods), &text, unshifted, action, now),
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
                ..
            } => self.resize(cols, rows, cell_px),
            In::Ack { version } => self.ack(version),
            In::Resync { model: false } => self.resync(),
            In::Resync { model: true } => {
                if let Some(m) = self.model.clone() {
                    self.send_model(m);
                }
            }
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
            In::Scroll {
                req,
                from,
                delta,
                prompt_delta,
                to,
            } => {
                let key = self.scroll(from.as_deref(), delta, prompt_delta, to.as_deref());
                self.answer(req, serde_json::json!({ "key": key }));
            }
            In::Fetch {
                req,
                before_key,
                max_bytes,
            } => {
                let version = self.fetch(
                    before_key.as_deref(),
                    max_bytes.unwrap_or(BACKFILL_MAX_BYTES),
                );
                self.answer(req, serde_json::json!({ "version": version }));
            }
            In::Search { req, query, dir } => {
                let matches = self.search(&query, dir.as_deref() != Some("down"));
                let (model, held) = matches_model(&matches);
                let version = self.attach.is_some().then(|| {
                    self.send_model(model);
                    self.model_version
                });
                let found = matches.len();
                self.answer(
                    req,
                    serde_json::json!({ "found": found, "held": held, "model": version }),
                );
            }
            In::TextRange {
                req,
                from_key,
                to_key,
            } => {
                let text = self.text_range(from_key.as_deref(), to_key.as_deref());
                self.answer(req, serde_json::json!({ "text": text }));
            }
            In::Close { signal } => self.closing = Some(signal.unwrap_or(1)),
        }
    }

    /// A key event: its bytes go to the program, and a press's echo is drawn at once.  A release sends nothing unless
    /// the program asked for key event types (kitty flag 2); a repeat is then a press.
    pub fn key(
        &mut self,
        name: &str,
        mods: u16,
        text: &str,
        unshifted: u32,
        action: KeyAction,
        now: Ms,
    ) {
        let action = match action {
            _ if self.engine.kitty_flags() & KITTY_REPORT_EVENTS == 0 => {
                if action == KeyAction::Release {
                    return;
                }
                GHOSTTY_KEY_ACTION_PRESS
            }
            KeyAction::Press => GHOSTTY_KEY_ACTION_PRESS,
            KeyAction::Repeat => GHOSTTY_KEY_ACTION_REPEAT,
            KeyAction::Release => GHOSTTY_KEY_ACTION_RELEASE,
        };
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
        let b = self.engine.encode_key(code, mods, &text, unshifted, action);
        self.pty.extend_from_slice(&b);
        if action != GHOSTTY_KEY_ACTION_RELEASE {
            self.clock.key(now);
        }
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

    /// No hub draws this terminal from NOW (it went away, a new one connected and has not attached yet, or the editor
    /// left it): nothing is sent until the next attach, which starts with a reset; `detached-keep` counts from the
    /// first such moment.
    pub fn detach(&mut self, now: Ms) {
        self.attach = None;
        self.alone_since.get_or_insert(now);
        self.reset_due = true;
        self.clock.acked();
    }

    pub fn ack(&mut self, version: u64) {
        if version == self.version {
            self.clock.acked();
        }
        self.gallery.acked(version);
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
                        .set_scrollback(self.window.max(ENGINE_LINES_MIN), self.scrollback_bytes);
                    self.tracker.set_above_max(self.window);
                    self.backfill_due = true;
                    self.clock.touch();
                }
            }
            "scrollback-bytes" => {
                if let Some(n) = value.as_u64() {
                    self.scrollback_bytes = n as usize;
                    self.engine
                        .set_scrollback(self.window.max(ENGINE_LINES_MIN), self.scrollback_bytes);
                }
            }
            "clipboard-write" => {
                self.engine.sink().clipboard_write = value.as_bool().unwrap_or(false)
            }
            "cursor-style" => {
                self.engine.set_default_cursor(value.as_str(), None);
                self.clock.touch();
            }
            "image-storage-limit"
            | "image-file-medium"
            | "image-max-bytes"
            | "image-disk-max"
            | "image-fps"
            | "remote" => {
                let s = &mut self.gallery.settings;
                match (name, value) {
                    ("image-storage-limit", v) => {
                        s.storage_limit = v.as_u64().unwrap_or(s.storage_limit)
                    }
                    ("image-file-medium", v) => s.file_medium = v.as_bool().unwrap_or(false),
                    ("image-max-bytes", v) => {
                        s.max_bytes = v.as_u64().map_or(s.max_bytes, |n| n as usize)
                    }
                    ("image-disk-max", v) => s.disk_max = v.as_u64().unwrap_or(s.disk_max),
                    ("image-fps", v) => s.fps = v.as_f64().filter(|f| *f >= 0.0).unwrap_or(s.fps),
                    (_, v) => s.remote = v.as_bool().unwrap_or(false),
                }
                self.gallery.apply(&mut self.engine);
                self.clock.touch();
            }
            "enquiry-response" => {
                self.engine.sink().enquiry = value.as_str().unwrap_or_default().to_string()
            }
            // hours alone before the program ends (0: never)
            "detached-keep" => {
                if let Some(h) = value.as_f64().filter(|h| *h >= 0.0) {
                    self.keep = (h > 0.0).then_some((h * 3_600_000.0) as Ms);
                }
            }
            "title-report" => self
                .engine
                .set_title_report(value.as_bool().unwrap_or(false)),
            // mode 2027: grapheme clusters take the width Unicode gives them (`legacy`: each code point its own)
            "grapheme-width-method" => {
                self.engine
                    .set_mode_default(2027, false, value.as_str() != Some("legacy"))
            }
            // `[fg, bg, cursor]` then maybe `c0 … c15`, `#rrggbb` each ("": the built-in one; the palette only whole)
            "colours" => {
                let c: Vec<Option<[u8; 3]>> = value
                    .as_array()
                    .map(|a| a.iter().map(|v| v.as_str().and_then(hex)).collect())
                    .unwrap_or_default();
                if c.len() >= 3 {
                    let ansi: Option<[[u8; 3]; 16]> = (c.len() == 19)
                        .then(|| c[3..].iter().copied().collect::<Option<Vec<_>>>())
                        .flatten()
                        .and_then(|v| v.try_into().ok());
                    self.engine.set_colours(c[0], c[1], c[2], ansi.as_ref());
                    self.reset_due = true;
                    self.clock.touch();
                }
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
            return match self.lonely_until() {
                Some(t) if self.closing.is_none() => Next::At(t),
                _ => Next::Idle,
            };
        }
        let next = self.clock.next(now, self.backfill_due);
        match (next, self.animation_at()) {
            (Next::Idle, Some(t)) => Next::At(t),
            (Next::At(a), Some(t)) => Next::At(a.min(t)),
            (n, _) => n,
        }
    }

    /// When the next animation frame is drawn: when the engine says it is due, at most `image-fps` a second, and only
    /// while a window shows the terminal (none: nothing plays).
    fn animation_at(&self) -> Option<Ms> {
        let g = &self.gallery;
        if !g.visible || g.settings.fps <= 0.0 {
            return None;
        }
        let due = g.animation_due?;
        let gap = (1000.0 / g.settings.fps) as Ms;
        Some(g.animation_last.map_or(due, |l| due.max(l + gap)))
    }

    /// When the program ends for want of an editor (none: it does not).
    fn lonely_until(&self) -> Option<Ms> {
        Some(self.alone_since? + self.keep?)
    }

    /// Draw what changed now, whatever the clock says (the program ended).
    pub fn flush(&mut self, now: Ms) {
        if self.clock.dirty() {
            self.frame(now);
        }
    }

    /// Do what is due at NOW; returns what comes after.
    pub fn step(&mut self, now: Ms) -> Next {
        if self.attach.is_none() && self.lonely_until().is_some_and(|t| now >= t) {
            tracing::info!("no editor within detached-keep: ending the program");
            self.alone_since = None;
            self.closing = Some(libc::SIGHUP);
            return Next::Idle;
        }
        if self.animation_at().is_some_and(|t| now >= t) && !self.clock.in_flight() {
            self.clock.touch();
        }
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
            model: None,
        };
        self.out.push(Out::Patch {
            patch: Box::new(patch),
        });
    }

    /// Row KEY from CELLS, its image SLICES riding on the cells they cover (the row padded to them), for the next
    /// patch.
    fn build(&mut self, key: &str, cells: &[Cell], slices: &[Slice]) -> Row {
        let mut built = build(key, cells, self.engine.size().2.0, &mut self.styles);
        with_slices(&mut built, slices);
        self.gallery.note(&built.row, slices, self.version + 1);
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
        if self.gallery.visible {
            self.gallery.animation_due = self.engine.animation_tick(now);
            self.gallery.animation_last = Some(now);
        }
        self.engine.update(rows_n);
        let alt = self.engine.alt_screen();
        let reset = self.reset_due || alt != self.alt;
        let slices = self.gallery.slices(&mut self.engine, rows_n as i32);
        let mut screen: Vec<(RowId, bool)> = Vec::new();
        let mut cells: HashMap<RowId, Vec<Cell>> = HashMap::new();
        let mut ys: HashMap<RowId, i32> = HashMap::new();
        {
            let tracker = &self.tracker;
            let gallery = &self.gallery;
            let key_of = |id: &RowId| {
                tracker
                    .screen()
                    .iter()
                    .find(|(s, _)| s == id)
                    .map(|(_, k)| k)
            };
            // a row whose images changed is read again, though its cells did not change
            let images_changed = |id: &RowId, y: i32| {
                key_of(id).is_some_and(|k| {
                    gallery.sent(k) != slices.get(&y).map_or(&[][..], |v| v.as_slice())
                })
            };
            self.engine.rows(|id, dirty, y, r| {
                ys.insert(id, y);
                if y < 0 {
                    if !reset && key_of(&id).is_some() {
                        cells.insert(id, r.cells());
                    }
                    return;
                }
                let dirty = dirty || images_changed(&id, y);
                screen.push((id, dirty));
                if reset || dirty || key_of(&id).is_none() {
                    cells.insert(id, r.cells());
                }
            });
        }
        for (id, y) in &ys {
            if let Some(s) = slices.get(y) {
                self.gallery.seen(*id, s);
            }
        }
        let none: Vec<Slice> = Vec::new();
        let slices_of = |id: &RowId| {
            ys.get(id)
                .and_then(|y| slices.get(y))
                .unwrap_or(&none)
                .clone()
        };
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
                self.gallery.reset(self.version + 1);
                let ids: Vec<RowId> = screen.iter().map(|(id, _)| *id).collect();
                let keyed = self.tracker.reset(&ids);
                let rows: Vec<Row> = keyed
                    .iter()
                    .map(|(id, k)| {
                        let c = cells.remove(id).unwrap_or_default();
                        self.build(k, &c, &slices_of(id))
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
                self.gallery.gone(&plan.remove, self.version + 1);
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
                            let row = self.build(k, &c, &slices_of(id));
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
                    let row = self.build(k, &c, &slices_of(id));
                    if before.as_ref() != Some(&row) {
                        changed.push(row);
                    }
                }
                // over image-disk-max: rows above the screen show an evicted file's alt
                let on: std::collections::HashSet<String> =
                    slices.values().flatten().map(|s| s.file.clone()).collect();
                changed.extend(self.gallery.evict(&on));
                if !changed.is_empty() {
                    ops.push(Op::Replace(changed));
                }
                for (after, run) in &plan.insert {
                    let rows: Vec<Row> = run
                        .iter()
                        .map(|(id, k)| {
                            let c = cells.remove(id).unwrap_or_default();
                            self.build(k, &c, &slices_of(id))
                        })
                        .collect();
                    ops.push(Op::Insert {
                        after: after.clone(),
                        rows,
                    });
                }
                let mut gone = self.tracker.take_trimmed();
                gone.extend(self.tracker.forget(&stale));
                self.gallery.gone(&gone, self.version + 1);
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
        if std::mem::take(&mut self.prompt_due)
            && !alt
            && let Some((_, y)) = self.engine.cursor().at
            && let Some((_, k)) = self.tracker.screen().get(y as usize)
            && self.prompts.back() != Some(k)
        {
            self.prompts.push_back(k.clone());
            if self.prompts.len() > PROMPTS_MAX {
                self.prompts.pop_front();
            }
        }
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
            bracketed_paste: self.engine.mode(2004, false),
            key_events: self.engine.kitty_flags() & KITTY_REPORT_EVENTS != 0,
            title: self.engine.title(),
        }
    }

    /// Send the next chunk of rows above the screen the editor lacks: the newest gap first, at most
    /// `BACKFILL_MAX_BYTES`, inserted after the row the editor holds above it.
    fn backfill(&mut self) {
        self.backfill_chunk(None, BACKFILL_MAX_BYTES);
    }

    /// One backfill chunk of at most MAX_BYTES, from the newest gap (below BEFORE: the newest gap above that row); true
    /// when a patch went.
    fn backfill_chunk(&mut self, before: Option<&str>, max_bytes: usize) -> bool {
        let over = self.window.min(u16::MAX as usize) as u16;
        if over == 0 || self.alt || self.attach.is_none() {
            self.backfill_due = false;
            return false;
        }
        self.engine.update(over);
        let mut hist: Vec<RowId> = Vec::new();
        self.engine.rows(|id, _, y, _| {
            if y < 0 {
                hist.push(id);
            }
        });
        // the rows above BEFORE: up to its place in the history (all of it for a screen row)
        let limit = before
            .and_then(|k| {
                self.tracker
                    .above()
                    .find(|(_, a)| a == k)
                    .map(|(id, _)| *id)
            })
            .and_then(|id| hist.iter().position(|h| *h == id))
            .unwrap_or(hist.len());
        let Some(top) = (0..limit).rev().find(|&i| !self.tracker.held(&hist[i])) else {
            if before.is_none() {
                self.backfill_due = false;
            }
            return false;
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
            // a row that scrolled past unseen gets the images it was last drawn with (their alt if a file went)
            let slices = self.gallery.seen_slices(id);
            let mut built = build("", cells, px, &mut self.styles);
            with_slices(&mut built, &slices);
            let row = built.row;
            let n = serde_json::to_vec(&row).map_or(0, |v| v.len()) + 16;
            if !chunk.is_empty() && bytes + n > max_bytes {
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
            .map(|((id, mut row), (_, key))| {
                row.key = key;
                let slices = self.gallery.seen_slices(&id);
                self.gallery.note(&row, &slices, self.version + 1);
                row
            })
            .collect();
        // the insert first: the window may drop the anchor itself
        let mut ops = vec![Op::Insert {
            after: anchor,
            rows,
        }];
        let gone = self.tracker.take_trimmed();
        self.gallery.gone(&gone, self.version + 1);
        if !gone.is_empty() {
            ops.push(Op::Remove(gone));
        }
        self.send(false, ops, None);
        self.clock.backfilled();
        true
    }

    /// The attached view's model is now MODEL (a reset): its `view-model` goes out, from the version last sent.
    fn send_model(&mut self, model: serde_json::Value) {
        let Some(a) = &self.attach else { return };
        let base = self.model_version;
        self.model_version += 1;
        self.out.push(Out::Model {
            model: serde_json::json!({
                "view": a.view, "hub": a.hub, "base": base, "version": self.model_version, "reset": true,
                "model": &model,
            }),
        });
        self.model = Some(model);
    }

    fn answer(&mut self, req: u64, result: serde_json::Value) {
        self.out.push(Out::Answer { req, result });
    }

    /// The rows the editor holds, top first: the window above the screen, then the screen.
    fn held_keys(&self) -> Vec<Key> {
        self.tracker
            .above()
            .chain(self.tracker.screen().iter())
            .map(|(_, k)| k.clone())
            .collect()
    }

    /// The row key to scroll to (see `In::Scroll`).
    pub fn scroll(
        &mut self,
        from: Option<&str>,
        delta: Option<i64>,
        prompt_delta: Option<i64>,
        to: Option<&str>,
    ) -> Option<Key> {
        let keys = self.held_keys();
        let cursor = self
            .meta
            .as_ref()
            .map(|m| m.cursor.0.clone())
            .filter(|k| !k.is_empty())
            .or_else(|| keys.last().cloned());
        if to == Some("bottom") {
            return cursor;
        }
        let from = from.map(str::to_owned).or(cursor)?;
        let at = keys.iter().position(|k| *k == from)? as i64;
        if let Some(n) = prompt_delta {
            let place: Vec<i64> = self
                .prompts
                .iter()
                .filter_map(|p| keys.iter().position(|k| k == p).map(|i| i as i64))
                .collect();
            let pick = if n < 0 {
                let before: Vec<&i64> = place.iter().filter(|&&i| i < at).collect();
                before
                    .len()
                    .checked_sub(n.unsigned_abs() as usize)
                    .map(|i| *before[i])
            } else {
                place
                    .iter()
                    .filter(|&&i| i > at)
                    .nth((n.max(1) - 1) as usize)
                    .copied()
            };
            return pick.map(|i| keys[i as usize].clone());
        }
        let i = (at + delta.unwrap_or(0)).clamp(0, keys.len() as i64 - 1);
        Some(keys[i as usize].clone())
    }

    /// `fetch`: the next backfill chunk now; the version of the patch it went in.
    pub fn fetch(&mut self, before: Option<&str>, max_bytes: usize) -> Option<u64> {
        self.backfill_chunk(before, max_bytes.max(1))
            .then_some(self.version)
    }

    /// Every row the engine holds, top first: its key when the editor holds it, and its text.
    fn all_rows(&mut self) -> Vec<(Option<Key>, String)> {
        let lines = (self.engine.scrollback_rows()).min(u16::MAX as usize) as u16;
        self.engine.update(lines);
        let held: HashMap<RowId, Key> = self
            .tracker
            .above()
            .chain(self.tracker.screen().iter())
            .cloned()
            .collect();
        let mut out = Vec::new();
        self.engine.rows(|id, _, _, r| {
            let text: String = r
                .cells()
                .iter()
                .map(|c| {
                    if c.text.is_empty() {
                        " "
                    } else {
                        c.text.as_str()
                    }
                })
                .collect();
            out.push((held.get(&id).cloned(), text.trim_end().to_owned()));
        });
        out
    }

    /// `search`: `[key, col, len]` of each match of QUERY (columns and lengths in characters), newest first when UP.
    pub fn search(&mut self, query: &str, up: bool) -> Vec<(Option<Key>, u32, u32)> {
        if query.is_empty() {
            return Vec::new();
        }
        let len = query.chars().count() as u32;
        let mut found = Vec::new();
        for (key, text) in self.all_rows() {
            for (b, _) in text.match_indices(query) {
                found.push((key.clone(), text[..b].chars().count() as u32, len));
            }
        }
        if up {
            found.reverse();
        }
        found
    }

    /// `text-range`: the rows from FROM to TO (keys; none: the oldest row the engine holds, the last row), one line
    /// each, without the empty rows below the last that holds text.
    pub fn text_range(&mut self, from: Option<&str>, to: Option<&str>) -> String {
        let rows = self.all_rows();
        let start = from
            .and_then(|f| rows.iter().position(|(k, _)| k.as_deref() == Some(f)))
            .unwrap_or(0);
        let mut end = to
            .and_then(|t| rows.iter().position(|(k, _)| k.as_deref() == Some(t)))
            .unwrap_or(rows.len().saturating_sub(1));
        if to.is_none() {
            while end > start && rows[end].1.is_empty() {
                end -= 1;
            }
        }
        if rows.is_empty() || end < start {
            return String::new();
        }
        rows[start..=end]
            .iter()
            .map(|(_, t)| t.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// The most matches Find's model holds: Sjá's cap on a list sent whole (the oldest past it are left out).
const MODEL_MATCHES_MAX: usize = 20_000;

/// Find's model from a search's MATCHES: a `list` scheme whose list `matches` holds, in their order, those in rows the
/// editor holds (id `KEY:COL`, fields `key`, `col`, `len`), as one reset op; and how many it holds.
/// BUILT with its image SLICES riding on the cells they cover, the row padded to them.
fn with_slices(built: &mut crate::style::Built, slices: &[Slice]) {
    if let Some(need) = slices.iter().map(|s| s.col1 as usize).max()
        && built.cols.len() < need
    {
        let mut pos = built.row.text.chars().count() as u32;
        while built.cols.len() < need {
            built.cols.push(pos);
            built.row.text.push(' ');
            pos += 1;
        }
    }
    let len = built.row.text.chars().count() as u32;
    for s in slices {
        let start = built.cols[s.col0 as usize];
        let end = built.cols.get(s.col1 as usize).copied().unwrap_or(len);
        built
            .row
            .props
            .push((start, end, IMAGE_PROP.to_owned(), s.value()));
    }
}

fn matches_model(matches: &[(Option<Key>, u32, u32)]) -> (serde_json::Value, usize) {
    let (mut nodes, mut ids) = (Vec::new(), Vec::new());
    for (key, col, len) in matches {
        if ids.len() >= MODEL_MATCHES_MAX {
            break;
        }
        let Some(key) = key else { continue };
        let id = format!("{key}:{col}");
        nodes.push(serde_json::json!({"id": id, "kind": "match", "flags": 0,
                                      "fields": [["key", key], ["col", col], ["len", len]]}));
        ids.push(id);
    }
    let n = ids.len();
    let model = serde_json::json!({"ops": [{"reset": {
        "descriptor": {"scheme": "list", "chain_kinds": [], "match_fields": [], "lists": ["matches"],
                       "classes": ["selected"], "flags": [], "forms": [], "start": "matches"},
        "nodes": nodes, "edges": [], "lists": [{"name": "matches", "ids": ids}],
    }}]});
    (model, n)
}

/// `#rrggbb` as bytes.
fn hex(s: &str) -> Option<[u8; 3]> {
    let h = s.strip_prefix('#').filter(|h| h.len() == 6)?;
    let b = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some([b(0)?, b(2)?, b(4)?])
}
