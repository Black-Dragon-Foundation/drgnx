//! Agents in the editor's buffers (agent system part 3; `docs/develop/hub.md`, "The buffer view").
//!
//! - [`buffer_view`]: which views get a frame and when (pure).
//!
//! The shell here keeps the views of every connection ([`Buffers`]), hears the presence model's changes, and builds a
//! frame for each view the core says is due: the agents in the file (from presence, with their identities and what
//! they are doing) and the gutter (an agent's own worktree: the lines its latest step snapshot changed against the
//! base, the interim before the edit history; an edit about to land: its pending lines). Nothing is built for a file
//! no view shows.

pub mod buffer_view;

use crate::dispatch::Caller;
use crate::front::Front;
use crate::work::presence::{self, RepoPath};
use buffer_view::{ViewEv, ViewOut, Views};
use runstav::methods::editor::{
    BufferAgent, BufferFrame, BufferUnwatch, BufferWatch, GutterKind, GutterRange,
};
use runstav::methods::work::PresenceMode;
use runstav::wire::Error;
use serde_json::json;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::Duration;

/// A view gets at most one frame per this much of the hub's clock.
pub const FRAME_EVERY: Duration = Duration::from_millis(50);

/// After the user changes a buffer, its frame waits for this much quiet.
pub const USER_QUIET: Duration = Duration::from_millis(300);

/// The editors' buffer views (see the module).
#[derive(Default)]
pub struct Buffers {
    views: Mutex<Views>,
    front: OnceLock<Weak<Front>>,
    /// Frame bodies built since the hub started (a test's count: an unwatched file builds none).
    built: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What a frame shows of one file.
struct Body {
    agents: Vec<BufferAgent>,
    gutter: Vec<GutterRange>,
    approximate: Option<bool>,
}

/// The keys a change of FILE names: the file, and `REPO:REL` (the same file in every worktree of its repository).
fn keys(front: &Front, file: &str) -> Vec<String> {
    let mut keys = vec![file.to_string()];
    if let Some((rel, repo)) = front.core.presence.rel_and_repo(file) {
        keys.push(format!("{repo}:{rel}"));
    }
    keys
}

impl Buffers {
    /// The front, kept once at the hub's start; the presence model's changes reach the views from then on.
    pub fn bind(self: &Arc<Self>, front: &Arc<Front>) {
        if self.front.set(Arc::downgrade(front)).is_ok() {
            let me = Arc::downgrade(self);
            front
                .core
                .presence
                .on_change(Arc::new(move |files: &[RepoPath]| {
                    if let Some(b) = me.upgrade() {
                        b.changed(files);
                    }
                }));
        }
    }

    fn front(&self) -> Option<Arc<Front>> {
        self.front.get().and_then(Weak::upgrade)
    }

    /// What is in FILES changed: the views showing them are due (nothing is done while no view is open).
    pub fn changed(self: &Arc<Self>, files: &[RepoPath]) {
        if lock(&self.views).is_empty() {
            return;
        }
        let Some(front) = self.front() else { return };
        let keys: Vec<String> = files.iter().flat_map(|f| keys(&front, f)).collect();
        let outs = lock(&self.views).step(ViewEv::Changed { keys });
        self.perform(outs);
    }

    /// The core's effects that are timers: the flush, a user change's quiet.
    fn perform(self: &Arc<Self>, outs: Vec<ViewOut>) {
        for o in outs {
            match o {
                ViewOut::Arm => {
                    let me = self.clone();
                    crate::clock::spawn("editor:flush", async move {
                        crate::clock::sleep(FRAME_EVERY).await;
                        me.flush().await;
                    });
                }
                ViewOut::Idle {
                    conn,
                    view,
                    generation,
                } => {
                    let me = self.clone();
                    crate::clock::spawn("editor:quiet", async move {
                        crate::clock::sleep(USER_QUIET).await;
                        let outs = lock(&me.views).step(ViewEv::UserIdle {
                            conn,
                            view,
                            generation,
                        });
                        me.perform(outs);
                    });
                }
                ViewOut::Full { .. } | ViewOut::Frame { .. } | ViewOut::NoView => {}
            }
        }
    }

    /// The due views' frames, each file built once, each to its own connection.
    async fn flush(self: &Arc<Self>) {
        let outs = lock(&self.views).step(ViewEv::Flush);
        let Some(front) = self.front() else { return };
        let mut bodies: BTreeMap<String, Body> = BTreeMap::new();
        for o in outs {
            let ViewOut::Frame {
                conn,
                view,
                file,
                version,
                base,
                doc_version,
            } = o
            else {
                continue;
            };
            if !bodies.contains_key(&file) {
                let b = self.body(&front, &file).await;
                bodies.insert(file.clone(), b);
            }
            let frame = frame_of(view, version, base, doc_version, &bodies[&file]);
            if !front.send_to(conn, "agent-buffer", json!(frame)) {
                self.gone(conn);
            }
        }
    }

    /// What a view of FILE shows now.
    async fn body(&self, front: &Front, file: &str) -> Body {
        self.built.fetch_add(1, Ordering::Relaxed);
        let now = crate::clock::wall_secs();
        let ids = &front.core.agents.identities;
        let handle = |s: &str| {
            ids.get(s)
                .map_or_else(|| "an agent".to_string(), |i| i.handle)
        };
        let entries: Vec<presence::Entry> = front
            .core
            .presence
            .now_in(&[file.to_string()])
            .into_iter()
            .flat_map(|(_, e)| e)
            .collect();
        let mut agents = Vec::new();
        let mut gutter = Vec::new();
        for e in &entries {
            let id = ids.get(&e.session);
            agents.push(BufferAgent {
                session: e.session.clone(),
                ordinal: id.as_ref().map(|i| i.ordinal),
                handle: id.map(|i| i.handle),
                mode: e.mode,
                line: e.line,
                line_end: e.line_end,
                col: e.col,
                source: e.source,
                live: e.live,
                projected: None,
                step_title: front.core.agents.doing(&e.session),
                plan_entry: None,
            });
            if e.mode == PresenceMode::Pending
                && let Some(line) = e.line
            {
                gutter.push(GutterRange {
                    session: e.session.clone(),
                    kind: GutterKind::Pending,
                    start: line,
                    end: e.line_end.unwrap_or(line).max(line),
                    projected: None,
                    help: format!("{} · about to change", handle(&e.session)),
                });
            }
        }
        // an agent's own worktree: what its latest step snapshot changed against the base
        for s in front.core.agents.live_sessions() {
            let wt = s.worktree();
            let Ok(rel) = Path::new(file).strip_prefix(&wt) else {
                continue;
            };
            let rel = rel.to_string_lossy().into_owned();
            if let Ok(Some(c)) = crate::work::edits::changed_lines(front, &s.id, &rel).await {
                let help =
                    buffer_view::help_text(&handle(&s.id), Some(c.seq), c.at.unwrap_or(now), now);
                gutter.extend(c.ranges.into_iter().map(|(start, end)| GutterRange {
                    session: s.id.clone(),
                    kind: GutterKind::Changed,
                    start,
                    end,
                    projected: None,
                    help: help.clone(),
                }));
            }
        }
        Body {
            agents,
            gutter: buffer_view::merge_gutter(gutter),
            approximate: None,
        }
    }

    /// Connection CONN is gone: its views with it.
    pub fn gone(&self, conn: u64) {
        lock(&self.views).step(ViewEv::Gone { conn });
    }

    /// The views open now, and the frame bodies built so far.
    pub fn counts(&self) -> (usize, u64) {
        (lock(&self.views).len(), self.built.load(Ordering::Relaxed))
    }
}

fn frame_of(
    view: String,
    version: u64,
    base: u64,
    doc_version: Option<u64>,
    b: &Body,
) -> BufferFrame {
    BufferFrame {
        view,
        version,
        base,
        doc_version,
        approximate: b.approximate,
        agents: b.agents.clone(),
        gutter: b.gutter.clone(),
    }
}

/// `agents/buffer/watch`.
pub async fn watch(f: &Front, c: &Caller, p: BufferWatch) -> Result<BufferFrame, Error> {
    let b = f.core.buffers.clone();
    let file = presence::true_name(&p.file);
    let outs = lock(&b.views).step(ViewEv::Watch {
        conn: c.conn_id,
        view: p.view.clone(),
        file: file.clone(),
        keys: keys(f, &file),
        doc_version: p.doc_version,
    });
    let mut answer = None;
    let mut rest = Vec::new();
    for o in outs {
        match o {
            ViewOut::Full {
                view,
                version,
                doc_version,
                ..
            } => {
                let body = b.body(f, &file).await;
                answer = Some(frame_of(view, version, 0, doc_version, &body));
            }
            other => rest.push(other),
        }
    }
    b.perform(rest);
    answer.ok_or_else(|| crate::runner::invalid("the view was not opened"))
}

/// `agents/buffer/unwatch`.
pub fn unwatch(f: &Front, c: &Caller, p: BufferUnwatch) -> Result<bool, Error> {
    let outs = lock(&f.core.buffers.views).step(ViewEv::Unwatch {
        conn: c.conn_id,
        view: p.view,
    });
    Ok(!outs.contains(&ViewOut::NoView))
}
