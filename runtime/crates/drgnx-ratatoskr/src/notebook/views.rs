//! A notebook's Sjá views (design §4.4, docs/develop/notebooks.md "The views"): hub-fed views whose rows the hub builds and Lisp
//! only inserts. `notebook/view` names a view for a notebook (the editor then sends `view/env` as for any hub-fed view); the rows of
//! each view are rebuilt, and what changed sent as a patch, when the notebook changes: a cell's tail or the kernel's state (the events
//! the hub sends the editor, seen on their way by [`WatchSink`]), or the editor's cells (`notebook/sync`, `execute`, `save`, `clear`).
//! Changes are coalesced: a view is rebuilt at most once in [`VIEW_EVERY`], and only when the editor shows it.
//!
//! - the cell outline, `notebook-outline:ID`: one row per cell (index, type, prompt, first line, state); a row carries the text
//!   property `drgnx-notebook-cell` (the cell's id) for the editor to jump to the cell. At most [`OUTLINE_ROWS`] cells are listed.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use drgnx_rows::{Row, RowBuilder};
use hrafn::notebook::Kind;
use runstav::methods::notebook::NotebookViewKind;
use serde_json::{Value, json};

use super::hub::Notebooks;
use super::output::terminal::clean;
use crate::debug::{Delivery, Sink};
use crate::front::Front;

/// The least time between two rebuilds of a notebook's views.
pub const VIEW_EVERY: Duration = Duration::from_millis(100);
/// The most cells the outline lists; what is past them is one row, "N more cells".
pub const OUTLINE_ROWS: usize = 2000;
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

/// The outline's rows for CELLS, the first [`OUTLINE_ROWS`] of TOTAL: `INDEX  type  [n]  first line  state`, the index counted from 1.
pub fn outline_rows(cells: &[OutlineCell], total: usize) -> Vec<Row> {
    let width = total.to_string().len();
    let mut rows = Vec::with_capacity(cells.len() + 1);
    for (i, c) in cells.iter().enumerate() {
        let mut b = RowBuilder::new(format!("cell:{}", c.id));
        b.push(&format!("{:>width$}", i + 1), Some("shadow"))
            .push("  ", None)
            .push(&format!("{:<8}", kind_name(c.kind)), Some("shadow"));
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
        b.push(&format!("{prompt:<7}"), Some(face))
            .push(&c.first_line, None);
        let state = match c.state {
            "queued" | "running" => Some("drgnx-status-warn"),
            "error" => Some("drgnx-status-fail"),
            "aborted" | "cancelled" => Some("shadow"),
            _ => None,
        };
        if let Some(face) = state {
            b.push("  ", None).push(c.state, Some(face));
        }
        let end = b.pos();
        b.prop(0, end, "drgnx-notebook-cell", json!(c.id));
        rows.push(b.finish());
    }
    if total > cells.len() {
        let mut b = RowBuilder::new("more");
        b.push(
            &format!("{} more cells", total - cells.len()),
            Some("shadow"),
        );
        rows.push(b.finish());
    }
    rows
}

/// Where a view's rows go: the editor's views of the hub.
pub trait Stage: Send + Sync {
    /// Whether the editor on CONN shows VIEW in some display class.
    fn shown(&self, conn: u64, view: &str) -> bool;
    /// VIEW's rows are ROWS: what changed goes out.
    fn publish(&self, conn: u64, view: &str, rows: Vec<Row>);
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
}

/// What a view of one notebook needs rebuilding.
#[derive(Default)]
struct Dirty {
    outline: bool,
}

#[derive(Default)]
struct Watch {
    outline: bool,
}

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

    /// The editor on CONN wants a view of KIND of notebook ID (which it owns): the view's id.
    pub fn register(&self, conn: u64, id: &str, kind: NotebookViewKind) -> String {
        let mut s = self.lock();
        let w = s.watch.entry((conn, id.to_owned())).or_default();
        match kind {
            NotebookViewKind::Outline => {
                w.outline = true;
                outline_view(id)
            }
        }
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
        if matches!(event, "notebook-tail" | "notebook-status")
            && let Some(id) = data.get("id").and_then(Value::as_str)
        {
            self.changed(conn, id);
        }
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

    /// CONN's VIEW got its env: if it is a notebook view the editor asked for, its rows are built now (true).
    pub fn env_build(self: &Arc<Self>, conn: u64, view: &str) -> bool {
        let Some(id) = outline_of(view) else {
            return false;
        };
        let key = (conn, id.to_owned());
        {
            let mut s = self.lock();
            if !s.watch.get(&key).is_some_and(|w| w.outline) {
                return false;
            }
            s.dirty.entry(key).or_default().outline = true;
        }
        let me = self.clone();
        crate::clock::spawn("notebook:view-env", async move { me.flush().await });
        true
    }

    /// Build the rows of every view that is dirty and shown, and send what changed.
    pub async fn flush(&self) {
        let work: Vec<((u64, String), Dirty)> = self.lock().dirty.drain().collect();
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
                    stage.publish(conn, &view, outline_rows(&cells, total));
                }
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
