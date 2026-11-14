//! A notebook's Sjá views (design §4.4, docs/develop/notebooks.md "The views"): hub-fed views whose rows the hub builds and Lisp
//! only inserts. `notebook/view` names a view for a notebook (the editor then sends `view/env` as for any hub-fed view); the rows of
//! each view are rebuilt, and what changed sent as a patch, when the notebook changes: a cell's tail or the kernel's state (the events
//! the hub sends the editor, seen on their way by [`WatchSink`]), or the editor's cells (`notebook/sync`, `execute`, `save`, `clear`).
//! Changes are coalesced: a view is rebuilt at most once in [`VIEW_EVERY`], and only when the editor shows it.
//!
//! - the full output of one cell, `notebook-output:ID#N` (N names the cell: the hub keeps up to [`OUTPUT_VIEWS`] a notebook): the
//!   cell's lines as the hub holds them, within the output limits (1 MiB of text, 64 outputs), [`OUTPUT_WINDOW`] lines at a time:
//!   `view/window` (list `lines`) moves the window, and a row above and below says how many lines lie outside it. An image is a row
//!   that says so, never drawn; a kernel's SVG is never rendered.
//! - the kernel log, `notebook-log:ID`: what the kernel says that answers no cell (an empty parent header: its own logging, a message
//!   from another client), the last [`LOG_ENTRIES`] of it, one row per line of an entry (at most [`LOG_LINES`] lines each, each cut at
//!   [`LOG_LINE_CHARS`] characters). `notebook/log` returns the same entries as data.
//! - the cell outline, `notebook-outline:ID`: one row per cell (index, type, prompt, first line, state); a row carries the text
//!   property `drgnx-notebook-cell` (the cell's id) for the editor to jump to the cell. At most [`OUTLINE_ROWS`] cells are listed.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use drgnx_rows::{Row, RowBuilder};
use hrafn::notebook::Kind;
use runstav::methods::notebook::NotebookViewKind;
use serde_json::{Value, json};

use super::hub::Notebooks;
use super::output::terminal::{Run, clean};
use super::output::{CellRun, LOG_ENTRIES};
use super::tail;
use crate::debug::{Delivery, Sink};
use crate::front::Front;

/// The least time between two rebuilds of a notebook's views.
pub const VIEW_EVERY: Duration = Duration::from_millis(100);
/// The most cells the outline lists; what is past them is one row, "N more cells".
pub const OUTLINE_ROWS: usize = 2000;
/// The most full-output views one notebook has at once.
pub const OUTPUT_VIEWS: usize = 16;
/// The lines of a full output the hub builds rows for at a time.
pub const OUTPUT_WINDOW: usize = 1000;
/// The lines of one log entry that are shown, and the characters of a line.
pub const LOG_LINES: usize = 8;
pub const LOG_LINE_CHARS: usize = 400;
/// The longest first line the outline shows, in characters.
pub const FIRST_LINE_CHARS: usize = 80;

/// The view id of notebook ID's outline.
pub fn outline_view(id: &str) -> String {
    format!("notebook-outline:{id}")
}

/// The notebook an outline view id names.
fn outline_of(view: &str) -> Option<&str> {
    view.strip_prefix("notebook-outline:")
}

/// The view id of the N-th full-output view of notebook ID.
pub fn output_view(id: &str, n: usize) -> String {
    format!("notebook-output:{id}#{n}")
}

/// The notebook and the number a full-output view id names.
fn output_of(view: &str) -> Option<(&str, usize)> {
    let (id, n) = view.strip_prefix("notebook-output:")?.split_once('#')?;
    Some((id, n.parse().ok()?))
}

/// The view id of notebook ID's kernel log.
pub fn log_view(id: &str) -> String {
    format!("notebook-log:{id}")
}

/// One message the kernel sent that answered no cell: SEQ counts from 1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEntry {
    pub seq: u64,
    pub msg_type: String,
    pub text: String,
}

/// A notebook's kernel log: the last [`LOG_ENTRIES`] entries (each already cut by the router), kept across a kernel's restarts.
#[derive(Debug, Default)]
pub struct KernelLog {
    last: u64,
    entries: VecDeque<LogEntry>,
}

impl KernelLog {
    /// File an entry; its number.
    pub fn push(&mut self, msg_type: &str, text: &str) -> u64 {
        self.last += 1;
        if self.entries.len() >= LOG_ENTRIES {
            self.entries.pop_front();
        }
        self.entries.push_back(LogEntry {
            seq: self.last,
            msg_type: msg_type.to_owned(),
            text: text.to_owned(),
        });
        self.last
    }

    /// The number of the newest entry (0: none yet).
    pub fn last_seq(&self) -> u64 {
        self.last
    }

    /// The entries numbered above AFTER, and how many of those are no longer held.
    pub fn since(&self, after: u64) -> (Vec<LogEntry>, u64) {
        let oldest = self.entries.front().map_or(self.last + 1, |e| e.seq);
        let lost = oldest.saturating_sub(after.saturating_add(1));
        (
            self.entries
                .iter()
                .filter(|e| e.seq > after)
                .cloned()
                .collect(),
            lost,
        )
    }
}

/// The log view's rows: `TYPE  text` for the first line of an entry and the text of the others indented under it, a row `lost` first
/// when entries were dropped.
pub fn log_rows(entries: &[LogEntry], lost: u64) -> Vec<Row> {
    let mut rows = Vec::new();
    if lost > 0 {
        let mut b = RowBuilder::new("lost");
        b.push(&format!("{:<14}", "lost"), Some("shadow"))
            .push("  ", None)
            .push(&format!("{lost} earlier entries"), Some("shadow"));
        let end = b.pos();
        b.prop(0, end, "drgnx-notebook-lost", json!(lost));
        rows.push(b.finish());
    }
    if entries.is_empty() && lost == 0 {
        return vec![note_row("none", "the kernel has logged nothing")];
    }
    for e in entries {
        let ty: String = clean(&e.msg_type).chars().take(14).collect();
        let text = clean(&e.text);
        let mut lines: Vec<&str> = text.lines().collect();
        let more = lines.len().saturating_sub(LOG_LINES);
        lines.truncate(LOG_LINES);
        if lines.is_empty() {
            lines.push("");
        }
        for (k, line) in lines.iter().enumerate() {
            let mut b = RowBuilder::new(format!("e:{}:{k}", e.seq));
            if k == 0 {
                let chip = if e.msg_type == "error" {
                    "drgnx-chip-error"
                } else {
                    "drgnx-chip-quiet"
                };
                b.push(&ty, Some(chip)).push(
                    &" ".repeat(14usize.saturating_sub(ty.chars().count())),
                    None,
                );
            } else {
                b.push(&" ".repeat(14), None);
            }
            b.push("  ", None);
            let shown: String = line
                .replace('\t', " ")
                .chars()
                .take(LOG_LINE_CHARS)
                .collect();
            b.push(&shown, None);
            if k + 1 == lines.len() && more > 0 {
                b.push(&format!("  ({more} more lines)"), Some("shadow"));
            }
            let n = b.pos();
            b.prop(0, n, "drgnx-notebook-log", json!(e.seq));
            if e.msg_type == "error" {
                b.face(0, n, "drgnx-notebook-error-row");
            }
            rows.push(b.finish());
        }
    }
    rows
}

/// What the outline knows of one cell. STATE is `queued`, `running`, or how its last run ended (`error`, `aborted`, `cancelled`),
/// else empty; STALE: its output is the file's own, no run of this hub made it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutlineCell {
    pub id: String,
    pub kind: Kind,
    pub first_line: String,
    pub execution_count: Option<i64>,
    pub state: &'static str,
    pub stale: bool,
}

/// The first line of SOURCE the outline shows: the first one with anything on it, trimmed, its control and direction-changing
/// characters gone, tabs as spaces, cut at [`FIRST_LINE_CHARS`] with an ellipsis. Only the start of a huge line is looked at.
pub fn first_line(source: &str) -> String {
    let line = source
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    // four bytes a character at most: a line of any length costs the same
    let head: String = line.chars().take(FIRST_LINE_CHARS * 4).collect();
    let cleaned: String = clean(&head.replace('\t', " "));
    let mut out: String = cleaned.chars().take(FIRST_LINE_CHARS).collect();
    if cleaned.chars().count() > FIRST_LINE_CHARS {
        out.pop();
        out.push('\u{2026}');
    }
    out
}

fn kind_name(k: Kind) -> &'static str {
    match k {
        Kind::Code => "code",
        Kind::Markdown => "markdown",
        Kind::Raw => "raw",
    }
}

/// The outline's rows for CELLS, the first [`OUTLINE_ROWS`] of TOTAL: `INDEX  type  [n]  first line  state`, the index counted from 1,
/// the type and the state chips (`drgnx-chip-*`). CURRENT is the cell the editor is in: its row carries the property
/// `drgnx-notebook-current` and, under the other faces, the face `drgnx-notebook-current-row`.
pub fn outline_rows(cells: &[OutlineCell], total: usize, current: Option<&str>) -> Vec<Row> {
    let width = total.to_string().len();
    let mut rows = Vec::with_capacity(cells.len() + 1);
    for (i, c) in cells.iter().enumerate() {
        let mut b = RowBuilder::new(format!("cell:{}", c.id));
        let kind = kind_name(c.kind);
        b.push(&format!("{:>width$}", i + 1), Some("shadow"))
            .push("  ", None)
            .push(kind, Some("drgnx-chip-quiet"))
            .push(&" ".repeat(8 - kind.len()), None);
        let prompt = match (c.kind, c.state, c.execution_count) {
            (Kind::Code, "queued" | "running", _) => "[*]".to_string(),
            (Kind::Code, _, Some(n)) => format!("[{n}]"),
            (Kind::Code, _, None) => "[ ]".to_string(),
            _ => String::new(),
        };
        let face = if c.stale {
            "drgnx-notebook-stale"
        } else {
            "drgnx-notebook-prompt"
        };
        b.push(&prompt, (!prompt.is_empty()).then_some(face))
            .push(
                &" ".repeat(7usize.saturating_sub(prompt.chars().count())),
                None,
            )
            .push(&c.first_line, None);
        let chip = match c.state {
            "running" => Some("drgnx-chip-accent"),
            "queued" => Some("drgnx-chip-quiet"),
            "error" => Some("drgnx-chip-error"),
            "aborted" | "cancelled" => Some("drgnx-chip-warn"),
            _ => None,
        };
        if let Some(face) = chip {
            b.push("  ", None).push(c.state, Some(face));
        }
        let end = b.pos();
        b.prop(0, end, "drgnx-notebook-cell", json!(c.id));
        if current == Some(c.id.as_str()) {
            b.prop(0, end, "drgnx-notebook-current", json!(true)).face(
                0,
                end,
                "drgnx-notebook-current-row",
            );
        }
        rows.push(b.finish());
    }
    if total > cells.len() {
        let n = total - cells.len();
        let mut b = RowBuilder::new("more");
        b.push(&format!("more: {n} cells are not listed"), Some("shadow"));
        let end = b.pos();
        b.prop(0, end, "drgnx-notebook-more", json!(n));
        rows.push(b.finish());
    }
    rows
}

/// The terminal's sixteen roles, in the hub's order (0 to 15): the names the faces `drgnx-notebook-fg-NAME` and `-bg-NAME` carry.
const ANSI_NAMES: [&str; 16] = [
    "black",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "white",
    "bright-black",
    "bright-red",
    "bright-green",
    "bright-yellow",
    "bright-blue",
    "bright-magenta",
    "bright-cyan",
    "bright-white",
];

fn note_row(key: &str, text: &str) -> Row {
    let mut b = RowBuilder::new(key);
    b.push(text, Some("shadow"));
    b.finish()
}

/// A row that counts the lines outside the output window: `ARROW N lines WHERE   KEY LABEL`, tinted (`drgnx-notebook-cut`), the key a
/// quiet chip, the number also the property PROP (so a reader never parses the text).
fn cut_row(
    key: &str,
    arrow: &str,
    n: usize,
    where_: &str,
    prop: &str,
    keys: &str,
    label: &str,
) -> Row {
    let mut b = RowBuilder::new(key);
    b.push(&format!("{arrow} {n} lines {where_}"), None)
        .push("   ", None)
        .push(keys, Some("drgnx-chip-quiet"))
        .push(&format!(" {label}"), Some("shadow"));
    let end = b.pos();
    b.prop(0, end, prop, json!(n))
        .face(0, end, "drgnx-notebook-cut");
    b.finish()
}

/// The faces over RUN's range of a line of LEN characters, as the tail's: the theme's terminal roles, never colours.
fn run_faces(b: &mut RowBuilder, r: &Run, len: usize) {
    let (start, end) = (r.start.min(len) as u32, r.end.min(len) as u32);
    if start >= end {
        return;
    }
    let s = r.style;
    if let Some(fg) = s.fg.filter(|n| *n < 16) {
        b.face(
            start,
            end,
            &format!("drgnx-notebook-fg-{}", ANSI_NAMES[fg as usize]),
        );
    }
    if let Some(bg) = s.bg.filter(|n| *n < 16) {
        b.face(
            start,
            end,
            &format!("drgnx-notebook-bg-{}", ANSI_NAMES[bg as usize]),
        );
    }
    for (on, face) in [
        (s.bold, "bold"),
        (s.italic, "italic"),
        (s.underline, "underline"),
        (s.inverse, "drgnx-notebook-inverse"),
    ] {
        if on {
            b.face(start, end, face);
        }
    }
}

/// The rows of CELL's full output, the [`OUTPUT_WINDOW`] lines from line FROM (0-based; what is past the end is brought back to the
/// last line): a row `above` and one `below` count the lines outside the window. An image is a row that says what it is.
pub fn output_rows(cell: &str, run: &CellRun, from: usize) -> Vec<Row> {
    let (total, lines) = tail::lines(run, from.saturating_add(OUTPUT_WINDOW));
    if total == 0 {
        return vec![note_row("none", "no output")];
    }
    let from = from.min(total - 1);
    let end = total.min(from + OUTPUT_WINDOW);
    let mut rows = Vec::new();
    if from > 0 {
        rows.push(cut_row(
            "above",
            "▲",
            from,
            "above",
            "drgnx-notebook-above",
            "M-p",
            "earlier lines",
        ));
    }
    for (i, l) in lines.iter().enumerate().skip(from).take(end - from) {
        let mut b = RowBuilder::new(format!("l:{i}"));
        match &l.image {
            Some((_, mime, w, h)) => {
                b.push(
                    &format!("[{mime} image, {w}x{h}: save output as file]"),
                    Some("shadow"),
                );
            }
            None => {
                let len = l.text.chars().count();
                // an empty line of an error has no text to tint: a space gives its row something to carry
                b.push(if l.error && len == 0 { " " } else { &l.text }, None);
                for r in &l.runs {
                    run_faces(&mut b, r, len);
                }
            }
        }
        let n = b.pos();
        if l.error {
            b.face(0, n, "drgnx-notebook-error-row");
        }
        b.prop(0, n, "drgnx-notebook-cell", json!(cell)).prop(
            0,
            n,
            "drgnx-notebook-line",
            json!(i + 1),
        );
        rows.push(b.finish());
    }
    if total > end {
        rows.push(cut_row(
            "below",
            "▼",
            total - end,
            "below",
            "drgnx-notebook-below",
            "M-n",
            "later lines",
        ));
    }
    rows
}

/// Where a view's rows go: the editor's views of the hub.
pub trait Stage: Send + Sync {
    /// Whether the editor on CONN shows VIEW in some display class.
    fn shown(&self, conn: u64, view: &str) -> bool;
    /// VIEW's rows are ROWS: what changed goes out.
    fn publish(&self, conn: u64, view: &str, rows: Vec<Row>);
    /// The first line of VIEW's window the editor asked for (0 before it asked).
    fn window(&self, conn: u64, view: &str) -> usize;
}

/// The hub's views as the stage.
struct FrontStage(Weak<Front>);

impl Stage for FrontStage {
    fn shown(&self, conn: u64, view: &str) -> bool {
        self.0
            .upgrade()
            .is_some_and(|f| !f.core.views.classes(conn, view).is_empty())
    }

    fn publish(&self, conn: u64, view: &str, rows: Vec<Row>) {
        if let Some(f) = self.0.upgrade() {
            f.core.views.publish_rows(&f, conn, view, rows);
        }
    }

    fn window(&self, conn: u64, view: &str) -> usize {
        self.0
            .upgrade()
            .and_then(|f| f.core.views.window_from(conn, view, "lines"))
            .unwrap_or(0)
    }
}

/// What a view of one notebook needs rebuilding.
#[derive(Default)]
struct Dirty {
    outline: bool,
    log: bool,
    /// The cells whose full output is to be rebuilt.
    outputs: HashSet<String>,
}

#[derive(Default)]
struct Watch {
    /// The cell the editor is in (the outline marks its row).
    current: Option<String>,
    outline: bool,
    log: bool,
    /// The cell of each full-output view, by its number.
    outputs: Vec<Option<String>>,
}

/// A notebook of a connection.
type Key = (u64, String);
/// The cells of a notebook's full-output views, by number.
type Slots = Vec<Option<String>>;
/// What a rebuild reads of a notebook's watch: its full-output views and the cell the editor is in.
type Snap = (Slots, Option<String>);

#[derive(Default)]
struct State {
    /// The notebooks (by connection and id) the editor asked a view of.
    watch: HashMap<(u64, String), Watch>,
    dirty: HashMap<(u64, String), Dirty>,
    /// A rebuild is waiting for [`VIEW_EVERY`] to pass.
    scheduled: bool,
}

/// The views of the hub's notebooks: which the editors asked for, and the rebuilds of their rows.
#[derive(Default)]
pub struct NbViews {
    state: Mutex<State>,
    nb: OnceLock<Weak<Notebooks>>,
    stage: OnceLock<Arc<dyn Stage>>,
}

impl NbViews {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().expect("notebook views")
    }

    /// The notebooks and the stage the views read and write (once; the first wins).
    pub fn attach(&self, nb: &Arc<Notebooks>, front: Option<Weak<Front>>) {
        let _ = self.nb.set(Arc::downgrade(nb));
        if let Some(f) = front {
            let _ = self.stage.set(Arc::new(FrontStage(f)));
        }
    }

    /// [`NbViews::attach`] with a stage of the caller's.
    pub fn attach_stage(&self, nb: &Arc<Notebooks>, stage: Arc<dyn Stage>) {
        let _ = self.nb.set(Arc::downgrade(nb));
        let _ = self.stage.set(stage);
    }

    /// The editor on CONN wants a view of KIND of notebook ID (which it owns; CELL for a full output): the view's id.
    pub fn register(
        &self,
        conn: u64,
        id: &str,
        kind: NotebookViewKind,
        cell: Option<&str>,
    ) -> Result<String, String> {
        let mut s = self.lock();
        let w = s.watch.entry((conn, id.to_owned())).or_default();
        match kind {
            NotebookViewKind::Outline => {
                w.outline = true;
                Ok(outline_view(id))
            }
            NotebookViewKind::Log => {
                w.log = true;
                Ok(log_view(id))
            }
            NotebookViewKind::Output => {
                let cell = cell.ok_or("a full output names its cell")?;
                let n = match w.outputs.iter().position(|c| c.as_deref() == Some(cell)) {
                    Some(n) => n,
                    None => match w.outputs.iter().position(Option::is_none) {
                        Some(n) => n,
                        None if w.outputs.len() < OUTPUT_VIEWS => {
                            w.outputs.push(None);
                            w.outputs.len() - 1
                        }
                        None => {
                            return Err(format!(
                                "{OUTPUT_VIEWS} outputs are shown: close one first"
                            ));
                        }
                    },
                };
                w.outputs[n] = Some(cell.to_owned());
                Ok(output_view(id, n))
            }
        }
    }

    /// The editor on CONN is in cell CELL of notebook ID (none: in none of its cells): the outline marks that cell's row. Whether this
    /// is a change.
    pub fn focus(self: &Arc<Self>, conn: u64, id: &str, cell: Option<&str>) -> bool {
        {
            let mut s = self.lock();
            let key = (conn, id.to_owned());
            let w = s.watch.entry(key.clone()).or_default();
            if w.current.as_deref() == cell {
                return false;
            }
            w.current = cell.map(str::to_owned);
            if w.outline {
                s.dirty.entry(key).or_default().outline = true;
            }
        }
        self.schedule();
        true
    }

    /// Notebook ID of CONN changed: its views are rebuilt soon.
    pub fn changed(self: &Arc<Self>, conn: u64, id: &str) {
        {
            let mut s = self.lock();
            let key = (conn, id.to_owned());
            let Some(w) = s.watch.get(&key) else { return };
            let outline = w.outline;
            let d = s.dirty.entry(key).or_default();
            d.outline |= outline;
        }
        self.schedule();
    }

    /// An event the hub sends CONN's editor: what it says changed.
    pub fn event(self: &Arc<Self>, conn: u64, event: &str, data: &Value) {
        if !matches!(event, "notebook-tail" | "notebook-status" | "notebook-log") {
            return;
        }
        let Some(id) = data.get("id").and_then(Value::as_str) else {
            return;
        };
        if event == "notebook-log" {
            let mut s = self.lock();
            let key = (conn, id.to_owned());
            if s.watch.get(&key).is_some_and(|w| w.log) {
                s.dirty.entry(key).or_default().log = true;
                drop(s);
                self.schedule();
            }
            return;
        }
        if event == "notebook-tail"
            && let Some(cell) = data.get("cell").and_then(Value::as_str)
        {
            let mut s = self.lock();
            let key = (conn, id.to_owned());
            if s.watch
                .get(&key)
                .is_some_and(|w| w.outputs.iter().any(|c| c.as_deref() == Some(cell)))
            {
                s.dirty
                    .entry(key)
                    .or_default()
                    .outputs
                    .insert(cell.to_owned());
            }
        }
        self.changed(conn, id);
    }

    fn schedule(self: &Arc<Self>) {
        {
            let mut s = self.lock();
            if s.scheduled {
                return;
            }
            s.scheduled = true;
        }
        let me = self.clone();
        crate::clock::spawn("notebook:views", async move {
            crate::clock::sleep(VIEW_EVERY).await;
            // before the rebuild: a change while it runs schedules the next
            me.lock().scheduled = false;
            me.flush().await;
        });
    }

    /// CONN's VIEW got its env, or its window moved: if it is a notebook view the editor asked for, its rows are built now (true).
    pub fn env_build(self: &Arc<Self>, conn: u64, view: &str) -> bool {
        {
            let mut s = self.lock();
            if let Some(id) = outline_of(view) {
                let key = (conn, id.to_owned());
                if !s.watch.get(&key).is_some_and(|w| w.outline) {
                    return false;
                }
                s.dirty.entry(key).or_default().outline = true;
            } else if let Some(id) = view.strip_prefix("notebook-log:") {
                let key = (conn, id.to_owned());
                if !s.watch.get(&key).is_some_and(|w| w.log) {
                    return false;
                }
                s.dirty.entry(key).or_default().log = true;
            } else if let Some((id, n)) = output_of(view) {
                let key = (conn, id.to_owned());
                let Some(cell) = s
                    .watch
                    .get(&key)
                    .and_then(|w| w.outputs.get(n))
                    .cloned()
                    .flatten()
                else {
                    return false;
                };
                s.dirty.entry(key).or_default().outputs.insert(cell);
            } else {
                return false;
            }
        }
        let me = self.clone();
        crate::clock::spawn("notebook:view-env", async move { me.flush().await });
        true
    }

    /// The editor moved VIEW's window: its rows are built again (true when it is a full-output view it asked for).
    pub fn window(self: &Arc<Self>, conn: u64, view: &str) -> bool {
        output_of(view).is_some() && self.env_build(conn, view)
    }

    /// The editor ended VIEW: a full-output view's number is free again.
    pub fn view_closed(&self, conn: u64, view: &str) {
        if let Some((id, n)) = output_of(view)
            && let Some(slot) = self
                .lock()
                .watch
                .get_mut(&(conn, id.to_owned()))
                .and_then(|w| w.outputs.get_mut(n))
        {
            *slot = None;
        }
    }

    /// Build the rows of every view that is dirty and shown, and send what changed.
    pub async fn flush(&self) {
        let (work, snaps): (Vec<(Key, Dirty)>, HashMap<Key, Snap>) = {
            let mut s = self.lock();
            let work: Vec<_> = s.dirty.drain().collect();
            let snaps = work
                .iter()
                .filter_map(|(k, _)| {
                    let w = s.watch.get(k)?;
                    Some((k.clone(), (w.outputs.clone(), w.current.clone())))
                })
                .collect();
            (work, snaps)
        };
        let (Some(nb), Some(stage)) = (self.nb.get().and_then(Weak::upgrade), self.stage.get())
        else {
            return;
        };
        for ((conn, id), d) in work {
            if d.outline {
                let view = outline_view(&id);
                if stage.shown(conn, &view)
                    && let Ok((total, cells)) = nb.outline(conn, &id, OUTLINE_ROWS).await
                {
                    let current = snaps.get(&(conn, id.clone())).and_then(|s| s.1.as_deref());
                    stage.publish(conn, &view, outline_rows(&cells, total, current));
                }
            }
            if d.log {
                let view = log_view(&id);
                if stage.shown(conn, &view)
                    && let Ok((entries, _, lost)) = nb.kernel_log(conn, &id, 0)
                {
                    stage.publish(conn, &view, log_rows(&entries, lost));
                }
            }
            for cell in &d.outputs {
                let Some(n) = snaps
                    .get(&(conn, id.clone()))
                    .and_then(|s| s.0.iter().position(|c| c.as_deref() == Some(cell)))
                else {
                    continue;
                };
                let view = output_view(&id, n);
                if !stage.shown(conn, &view) {
                    continue;
                }
                let rows = match nb.run_of(conn, &id, cell).await {
                    Ok(run) => output_rows(cell, &run, stage.window(conn, &view)),
                    Err(_) => vec![note_row("none", "the cell is gone")],
                };
                stage.publish(conn, &view, rows);
            }
        }
    }

    /// Notebook ID of CONN is closed.
    pub fn closed(&self, conn: u64, id: &str) {
        let key = (conn, id.to_owned());
        let mut s = self.lock();
        s.watch.remove(&key);
        s.dirty.remove(&key);
    }

    /// Connection CONN is gone.
    pub fn gone(&self, conn: u64) {
        let mut s = self.lock();
        s.watch.retain(|(c, _), _| *c != conn);
        s.dirty.retain(|(c, _), _| *c != conn);
    }

    /// Notebook ID of CONN is dirty, with no rebuild scheduled.
    #[cfg(test)]
    pub(crate) fn mark(&self, conn: u64, id: &str) {
        self.lock()
            .dirty
            .entry((conn, id.to_owned()))
            .or_default()
            .outline = true;
    }

    /// Nothing waits to be rebuilt.
    #[cfg(test)]
    pub(crate) fn dirty_is_empty(&self) -> bool {
        self.lock().dirty.is_empty()
    }

    /// The (connection, id) pairs with a view asked for.
    #[cfg(test)]
    pub(crate) fn watched(&self) -> std::collections::HashSet<(u64, String)> {
        self.lock().watch.keys().cloned().collect()
    }
}

/// The sink the notebooks send through: the editors' own, with each event also shown to the views.
pub struct WatchSink {
    pub inner: Arc<dyn Sink>,
    pub views: Arc<NbViews>,
}

impl Sink for WatchSink {
    fn broadcast(&self, event: &str, data: Value, except: Option<u64>) {
        self.inner.broadcast(event, data, except);
    }

    fn send(&self, conn: u64, event: &str, data: Value) -> bool {
        self.views.event(conn, event, &data);
        self.inner.send(conn, event, data)
    }

    fn send_lossy(&self, conn: u64, event: &str, data: Value) -> Delivery {
        self.views.event(conn, event, &data);
        self.inner.send_lossy(conn, event, data)
    }
}

#[cfg(test)]
mod tests;
