//! Agents in the editor's buffers (agent system part 3; `docs/develop/hub.md`, "The buffer view").
//!
//! - [`buffer_view`]: which views get a frame and when (pure).
//! - [`project`]: another worktree's agent mapped three-way onto the user's text (pure).
//! - [`follow`]: the follow feed (docs/develop/hub.md, "The follow feed").
//!
//! The shell here keeps the views of every connection ([`Buffers`]), hears the presence model's changes, and builds a
//! frame for each view the core says is due: the agents in the file (from presence, with their identities and what
//! they are doing), the agents of the repository's other worktrees projected onto it, and the gutter (an agent's own
//! worktree: the lines its latest step snapshot changed against the base, the interim before the edit history; an edit
//! about to land: its pending lines; a projected agent: its lines and its conflicts with the user's). Nothing is built
//! for a file no view shows.

pub mod buffer_view;
pub mod follow;
pub mod project;

use crate::dispatch::Caller;
use crate::front::Front;
use crate::work::presence::{self, RepoPath};
use buffer_view::{ViewEv, ViewOut, Views};
use runstav::methods::editor::{
    BufferAgent, BufferFrame, BufferUnwatch, BufferWatch, FollowParams, GutterKind, GutterRange,
    Projected, UnfollowParams,
};
use runstav::methods::work::PresenceMode;
use runstav::registry::Class;
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
    /// The worktrees' base texts, by (base tree, path).
    bases: Mutex<project::BaseCache>,
    /// Each watched file's latest body: the answer to a watch while the user types (it is built again after the
    /// quiet). Only files some view shows.
    last: Mutex<BTreeMap<String, Body>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What a frame shows of one file.
#[derive(Clone)]
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
        let projected = self.projected(front, file, &mut agents, &mut gutter).await;
        let body = Body {
            agents,
            gutter: buffer_view::merge_gutter(gutter),
            // the user's text is read from disk until the edit history's mirror
            approximate: (projected && project::UserSource::Disk.approximate()).then_some(true),
        };
        lock(&self.last).insert(file.to_string(), body.clone());
        body
    }

    /// The agents of FILE's repository working in its other worktrees, mapped three-way onto FILE (see
    /// [`project`]): pushed to AGENTS (those with an entry in their copy of the file) and GUTTER (their lines and
    /// their conflicts with the user's). Whether any agent changed or is in the file.
    async fn projected(
        &self,
        front: &Front,
        file: &str,
        agents: &mut Vec<BufferAgent>,
        gutter: &mut Vec<GutterRange>,
    ) -> bool {
        let Some((rel, repo)) = front.core.presence.rel_and_repo(file) else {
            return false;
        };
        let ids = &front.core.agents.identities;
        let sessions: Vec<(String, std::path::PathBuf)> = front
            .core
            .agents
            .live_sessions()
            .iter()
            .map(|s| (s.id.clone(), s.worktree()))
            .collect();
        if sessions.is_empty() {
            return false;
        }
        // the checkouts, from their `.git` entries: the user's, and each session's when it is another of the repository
        let user_file = file.to_string();
        let Ok((user_top, others)) = crate::clock::blocking(move || {
            let user_top = presence::checkout_of(Path::new(&user_file)).map(|(top, _)| top);
            let others: Vec<(String, std::path::PathBuf)> = sessions
                .into_iter()
                .filter_map(|(sid, wt)| {
                    let (top, r) = presence::checkout_of(&wt.join(".git"))?;
                    (r == repo).then_some((sid, top))
                })
                .collect();
            (user_top, others)
        })
        .await
        else {
            return false;
        };
        let mut user: Option<Arc<str>> = None;
        let mut any = false;
        for (sid, top) in others {
            if Some(&top) == user_top.as_ref() {
                continue;
            }
            let theirs = presence::true_name(&top.join(&rel).to_string_lossy());
            let entry = front
                .core
                .presence
                .now_in(std::slice::from_ref(&theirs))
                .into_iter()
                .flat_map(|(_, e)| e)
                .find(|e| e.session == sid);
            let Ok((root, wt, tree)) = crate::work::edits::base_of(front, &sid).await else {
                continue;
            };
            let cached = lock(&self.bases).get_or(&tree, &rel, || None);
            let base = match cached {
                Some(b) => b,
                None => {
                    let (t, p) = (tree.clone(), rel.clone());
                    // not in the base: a new file
                    let text = crate::clock::blocking(move || {
                        crate::work::edits::file_blob(&root, &wt, &t, &p)
                            .map(|b| String::from_utf8_lossy(&b).into_owned())
                            .unwrap_or_default()
                    })
                    .await
                    .unwrap_or_default();
                    lock(&self.bases)
                        .get_or(&tree, &rel, || Some(text))
                        .unwrap_or_else(|| Arc::from(""))
                }
            };
            if user.is_none() {
                let path = file.to_string();
                user = crate::clock::blocking(move || read_capped(Path::new(&path)))
                    .await
                    .ok()
                    .flatten()
                    .map(Arc::from);
            }
            let Some(user_text) = user.clone() else {
                return any;
            };
            let cursor = entry
                .as_ref()
                .and_then(|e| e.line)
                .map(|line| project::Pos { line });
            let has_entry = entry.is_some();
            let Ok(Some(p)) = crate::clock::blocking(move || {
                let agent = read_capped(Path::new(&theirs))?;
                if !has_entry && agent == *base {
                    return None;
                }
                Some(project::project(&base, &agent, &user_text, cursor))
            })
            .await
            else {
                continue;
            };
            any = true;
            let label = top
                .file_name()
                .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
            let projected = Some(Projected {
                worktree_label: label.clone(),
            });
            let who = ids
                .get(&sid)
                .map_or_else(|| "an agent".to_string(), |i| i.handle);
            if let Some(e) = entry {
                let id = ids.get(&sid);
                agents.push(BufferAgent {
                    session: sid.clone(),
                    ordinal: id.as_ref().map(|i| i.ordinal),
                    handle: id.map(|i| i.handle),
                    mode: e.mode,
                    line: p.cursor_on_user,
                    line_end: None,
                    col: None,
                    source: e.source,
                    live: e.live,
                    projected: projected.clone(),
                    step_title: front.core.agents.doing(&sid),
                    plan_entry: None,
                });
            }
            let ranges = |rs: Vec<project::LineRange>, kind: GutterKind, help: String| {
                rs.into_iter()
                    .map(|r| GutterRange {
                        session: sid.clone(),
                        kind,
                        start: r.start,
                        end: r.end,
                        projected: projected.clone(),
                        help: help.clone(),
                    })
                    .collect::<Vec<_>>()
            };
            gutter.extend(ranges(
                p.agent_ranges,
                GutterKind::Changed,
                format!("{who} · changed in {label} (projected)"),
            ));
            gutter.extend(ranges(
                p.conflicts,
                GutterKind::Conflict,
                format!("{who} · changed in {label}, where you changed it too (projected)"),
            ));
        }
        any
    }

    /// Forget the latest bodies of files no view shows.
    fn prune(&self) {
        let shown = lock(&self.views).files();
        lock(&self.last).retain(|f, _| shown.contains(f));
    }

    /// Connection CONN is gone: its views with it.
    pub fn gone(&self, conn: u64) {
        lock(&self.views).step(ViewEv::Gone { conn });
        self.prune();
    }

    /// The views open now, and the frame bodies built so far.
    pub fn counts(&self) -> (usize, u64) {
        (lock(&self.views).len(), self.built.load(Ordering::Relaxed))
    }
}

/// FILE's text, CRLF and all; none past [`crate::work::detail::EDIT_TEXT_MAX`] bytes, empty when it is not there.
fn read_capped(file: &Path) -> Option<String> {
    match std::fs::metadata(file) {
        Ok(m) if m.len() > crate::work::detail::EDIT_TEXT_MAX => None,
        Ok(_) => std::fs::read(file)
            .ok()
            .map(|b| String::from_utf8_lossy(&b).into_owned()),
        Err(_) => Some(String::new()),
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
    // the user is typing: the frame already built answers, and the file is projected again after the quiet
    let typing = outs.iter().any(|o| matches!(o, ViewOut::Idle { .. }));
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
                let kept = if typing {
                    lock(&b.last).get(&file).cloned()
                } else {
                    None
                };
                let body = match kept {
                    Some(k) => k,
                    None => b.body(f, &file).await,
                };
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
    f.core.buffers.prune();
    Ok(!outs.contains(&ViewOut::NoView))
}

/// `agents/follow`: the connection's view follows a session (the user's).
pub fn follow(f: &Front, c: &Caller, p: FollowParams) -> Result<bool, Error> {
    if c.class != Class::User {
        return Err(crate::agents::session::refuse(
            "only the user follows an agent",
        ));
    }
    f.core.agents.find(p.session.as_str())?;
    f.follows
        .follow(c.conn_id, p.view.0, p.session.as_str().to_string());
    Ok(true)
}

/// `agents/unfollow`: the connection's view follows nothing any more.
pub fn unfollow(f: &Front, c: &Caller, p: UnfollowParams) -> Result<bool, Error> {
    Ok(f.follows.unfollow(c.conn_id, p.view.0))
}
