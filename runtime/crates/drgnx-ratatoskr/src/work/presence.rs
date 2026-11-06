//! The presence model (docs/develop/hub.md, "The presence model"; docs/develop/work-space.md, "Presence"): who is in
//! which file, at which line, now. Part 2 builds it for the map's "who is here"; part 3's cursors, gutter and badges
//! read the same model through `agents/presence/subscribe` and the `agent-presence` event.
//!
//! An entry is a session's latest `(mode, line?, source, step, at)` in a file: from a read or search step's ACP fields
//! (`acp`), an edit step (`edit`), the files a shell step's command names (`command`) or opens (`opened`). An entry is
//! "now" while its session is live and it is younger than [`STALE_AFTER`], or it is the session's latest entry; older
//! ones stay as history. Each entry keeps its timeline step, so a shell step's reads are listed under it.
//!
//! [`Presence`] is pure: it takes the hub's times as arguments and keeps no store of its own; after a restart it is
//! rebuilt from the timeline's steps and their details ([`Presence::rebuild`]).
//!
//! **Live entries** (part 3): a tool call still running is fed as its `tool_call` / `tool_call_update` arrive
//! ([`Presence::apply_live`]), so a cursor moves before the step closes. A session's live entry in a file stands in
//! for its closed one there; the step's close replaces it ([`Presence::close_live`]: the closed step's entry, or
//! nothing for a failed or denied call), and an update that arrives for a call already closed is dropped, so the order
//! of the reader and the step writer does not matter. Live entries are never rebuilt after a restart.

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::work::{
    FilePresence, PresenceEntry, PresenceFiles, PresenceGet, PresenceMode as Mode,
    PresenceSource as Source, PresenceSubscribe,
};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Duration;

/// `presence-stale-after`: an entry older than this is history, unless it is its session's latest.
pub const STALE_AFTER: f64 = 120.0;

/// The most closed tool calls a session's live feed remembers (an update for one of them is dropped).
const CLOSED_CALLS: usize = 1024;

/// An absolute path in one of the workspace's repositories.
pub type RepoPath = String;

/// One session in one file.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub session: String,
    pub file: RepoPath,
    pub mode: Mode,
    pub line: Option<u32>,
    /// The last line of its range; none: `line` only.
    pub line_end: Option<u32>,
    /// The column after the last character an edit inserted (0-based, characters).
    pub col: Option<u32>,
    pub source: Source,
    /// The timeline step; 0 while live.
    pub step: i64,
    pub at: f64,
    /// From a tool call still running.
    pub live: bool,
    /// The tool call of a live entry.
    pub tool_call: Option<String>,
}

/// A file a step was in, and how.
#[derive(Clone, Debug, PartialEq)]
pub struct Touch {
    pub file: RepoPath,
    pub mode: Mode,
    pub line: Option<u32>,
    pub source: Source,
}

/// A tool call's ACP status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CallStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
}

/// What a running tool call's latest update says of the file it is in.
#[derive(Clone, Debug, PartialEq)]
pub struct LiveUpdate {
    pub path: RepoPath,
    pub mode: Mode,
    pub line: Option<u32>,
    pub line_end: Option<u32>,
    pub col: Option<u32>,
    pub status: CallStatus,
    pub source: Source,
    /// The hub's time of the update.
    pub at: f64,
}

/// What the model is told.
#[derive(Clone, Debug, PartialEq)]
pub enum PresenceEv {
    /// SESSION's timeline step STEP (at AT, the hub's time) was in FILES.
    Step {
        session: String,
        step: i64,
        at: f64,
        files: Vec<Touch>,
    },
    /// SESSION ended: none of its entries is "now" any more.
    SessionEnd { session: String },
    /// SESSION's tool call TOOL_CALL, still running, is where UPDATE says (a failed one is dropped).
    Live {
        session: String,
        tool_call: String,
        update: LiveUpdate,
    },
    /// SESSION's tool call TOOL_CALL ended: its live entry gives way to CLOSED, its step's entry (none: it failed or
    /// was denied).
    CloseLive {
        session: String,
        tool_call: String,
        closed: Option<Entry>,
    },
    /// SESSION's live entry under TOOL_CALL goes, and the call is not closed: an allowed permission request whose call
    /// the agent reports under an id of its own (its updates may still come under this one).
    Withdraw { session: String, tool_call: String },
}

/// What changed: a file whose entries may read differently now.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PresenceOut {
    Changed { file: RepoPath },
}

/// See the module.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Presence {
    /// Each session's latest entry per file.
    by_session: BTreeMap<String, BTreeMap<RepoPath, Entry>>,
    ended: BTreeSet<String>,
    /// Each session's running tool calls' entries, by tool call.
    live: BTreeMap<String, BTreeMap<String, Entry>>,
    /// Each session's tool calls that ended (the latest [`CLOSED_CALLS`]): an update for one is late and dropped.
    closed_calls: BTreeMap<String, VecDeque<String>>,
}

impl Presence {
    pub fn new() -> Presence {
        Presence::default()
    }

    pub fn apply(&mut self, ev: PresenceEv) -> Vec<PresenceOut> {
        let mut changed: BTreeSet<RepoPath> = BTreeSet::new();
        let session = match &ev {
            PresenceEv::Step { session, .. }
            | PresenceEv::SessionEnd { session }
            | PresenceEv::Live { session, .. }
            | PresenceEv::CloseLive { session, .. }
            | PresenceEv::Withdraw { session, .. } => session.clone(),
        };
        if self.ended.contains(&session) {
            return Vec::new();
        }
        let before = self.latest(&session).map(|e| e.file.clone());
        match ev {
            PresenceEv::Step {
                session,
                step,
                at,
                files,
            } => {
                for t in files {
                    let e = Entry {
                        session: session.clone(),
                        file: t.file,
                        mode: t.mode,
                        line: t.line,
                        line_end: None,
                        col: None,
                        source: t.source,
                        step,
                        at,
                        live: false,
                        tool_call: None,
                    };
                    self.put_closed(e, &mut changed);
                }
            }
            PresenceEv::SessionEnd { session } => {
                self.ended.insert(session.clone());
                if let Some(mine) = self.by_session.get(&session) {
                    changed.extend(mine.keys().cloned());
                }
                if let Some(mine) = self.live.remove(&session) {
                    changed.extend(mine.into_values().map(|e| e.file));
                }
                self.closed_calls.remove(&session);
            }
            PresenceEv::Live {
                session,
                tool_call,
                update,
            } => {
                let late = self
                    .closed_calls
                    .get(&session)
                    .is_some_and(|c| c.contains(&tool_call));
                if late {
                    return Vec::new();
                }
                let mine = self.live.entry(session.clone()).or_default();
                if update.status == CallStatus::Failed {
                    if let Some(old) = mine.remove(&tool_call) {
                        changed.insert(old.file);
                    }
                    self.close_call(&session, &tool_call);
                } else {
                    let e = Entry {
                        session: session.clone(),
                        file: update.path,
                        mode: update.mode,
                        line: update.line,
                        line_end: update.line_end,
                        col: update.col,
                        source: update.source,
                        step: 0,
                        at: update.at,
                        live: true,
                        tool_call: Some(tool_call.clone()),
                    };
                    let old = mine.insert(tool_call, e.clone());
                    if old.as_ref() != Some(&e) {
                        changed.extend(old.map(|o| o.file));
                        changed.insert(e.file);
                    }
                }
            }
            PresenceEv::CloseLive {
                session,
                tool_call,
                closed,
            } => {
                if let Some(old) = self
                    .live
                    .get_mut(&session)
                    .and_then(|m| m.remove(&tool_call))
                {
                    changed.insert(old.file);
                }
                self.close_call(&session, &tool_call);
                if let Some(mut e) = closed {
                    e.live = false;
                    e.tool_call = None;
                    self.put_closed(e, &mut changed);
                }
            }
            PresenceEv::Withdraw { session, tool_call } => {
                if let Some(old) = self
                    .live
                    .get_mut(&session)
                    .and_then(|m| m.remove(&tool_call))
                {
                    changed.insert(old.file);
                }
            }
        }
        // the session's latest moved: the file it left may read differently now
        let after = self.latest(&session).map(|e| e.file.clone());
        if before != after {
            changed.extend(before);
            changed.extend(after);
        }
        changed
            .into_iter()
            .map(|file| PresenceOut::Changed { file })
            .collect()
    }

    /// SESSION's tool call TOOL_CALL is running where UPDATE says (see [`PresenceEv::Live`]).
    pub fn apply_live(
        &mut self,
        session: &str,
        tool_call: &str,
        update: LiveUpdate,
    ) -> Vec<PresenceOut> {
        self.apply(PresenceEv::Live {
            session: session.into(),
            tool_call: tool_call.into(),
            update,
        })
    }

    /// SESSION's tool call TOOL_CALL ended (see [`PresenceEv::CloseLive`]).
    pub fn close_live(
        &mut self,
        session: &str,
        tool_call: &str,
        closed: Option<Entry>,
    ) -> Vec<PresenceOut> {
        self.apply(PresenceEv::CloseLive {
            session: session.into(),
            tool_call: tool_call.into(),
            closed,
        })
    }

    /// The step of SESSION's closed entry in FILE (0: none): where an entry no step carries (a pair write the editor
    /// applied) ranks beside the session's own.
    pub fn step_in(&self, session: &str, file: &str) -> i64 {
        self.by_session
            .get(session)
            .and_then(|m| m.get(file))
            .map_or(0, |e| e.step)
    }

    /// E as its session's entry in its file, when it ranks above the one there.
    fn put_closed(&mut self, e: Entry, changed: &mut BTreeSet<RepoPath>) {
        let mine = self.by_session.entry(e.session.clone()).or_default();
        if mine.get(&e.file).is_none_or(|old| rank(&e) > rank(old)) {
            changed.insert(e.file.clone());
            mine.insert(e.file.clone(), e);
        }
    }

    fn close_call(&mut self, session: &str, tool_call: &str) {
        let calls = self.closed_calls.entry(session.to_string()).or_default();
        if !calls.iter().any(|c| c == tool_call) {
            calls.push_back(tool_call.to_string());
            if calls.len() > CLOSED_CALLS {
                calls.pop_front();
            }
        }
    }

    /// SESSION's live entry in FILE: of its running calls there, the strongest mode, then the latest.
    fn live_in(&self, session: &str, file: &str) -> Option<&Entry> {
        self.live
            .get(session)?
            .values()
            .filter(|e| e.file == file)
            .max_by(|a, b| {
                (a.mode, a.at)
                    .partial_cmp(&(b.mode, b.at))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    }

    /// SESSION's latest entry: a running call's (the latest update), else of its highest step, the strongest mode.
    fn latest(&self, session: &str) -> Option<&Entry> {
        if let Some(e) = self.live.get(session).and_then(|m| {
            m.values()
                .max_by(|a, b| a.at.total_cmp(&b.at).then_with(|| b.file.cmp(&a.file)))
        }) {
            return Some(e);
        }
        self.by_session
            .get(session)?
            .values()
            .max_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| b.file.cmp(&a.file)))
    }

    /// Who is in FILE at AT: each live session's running call there, else its entry there that is younger than
    /// [`STALE_AFTER`] or is the session's latest, by session.
    pub fn now(&self, file: &str, at: f64) -> Vec<&Entry> {
        let sessions: BTreeSet<&String> = self.by_session.keys().chain(self.live.keys()).collect();
        sessions
            .into_iter()
            .filter(|s| !self.ended.contains(*s))
            .filter_map(|s| {
                if let Some(e) = self.live_in(s, file) {
                    return Some(e);
                }
                let e = self.by_session.get(s)?.get(file)?;
                let fresh = at - e.at < STALE_AFTER;
                (fresh || self.latest(s).is_some_and(|l| l.file == e.file)).then_some(e)
            })
            .collect()
    }

    /// The files under ROOT (a path prefix at a `/`) someone is in at AT.
    pub fn files_under(&self, root: &str, at: f64) -> Vec<RepoPath> {
        let all: BTreeSet<&RepoPath> = self
            .by_session
            .values()
            .flat_map(BTreeMap::keys)
            .chain(self.live.values().flat_map(|m| m.values().map(|e| &e.file)))
            .filter(|f| under(f, root))
            .collect();
        all.into_iter()
            .filter(|f| !self.now(f, at).is_empty())
            .cloned()
            .collect()
    }

    /// The model the live events would have built, from the timeline's STEPS (session, step id, time) and the files
    /// each was in (by step id).
    pub fn rebuild(steps: &[(String, i64, f64)], details: &BTreeMap<i64, Vec<Touch>>) -> Presence {
        let mut p = Presence::new();
        for (session, step, at) in steps {
            let files = details.get(step).cloned().unwrap_or_default();
            p.apply(PresenceEv::Step {
                session: session.clone(),
                step: *step,
                at: *at,
                files,
            });
        }
        p
    }
}

/// An entry's order among a session's: the later step wins, then the stronger mode, the known line, the source.
fn rank(e: &Entry) -> (i64, Mode, Option<u32>, Source) {
    (e.step, e.mode, e.line, e.source)
}

/// The files a shell step's command names, as presence: reads and scripts read, writes written, listings listed;
/// none has a line.
pub fn touches_of_command(r: &crate::work::shell_read::Resolved) -> Vec<Touch> {
    let of = |paths: &[PathBuf], mode| {
        paths
            .iter()
            .map(move |p| Touch {
                file: p.to_string_lossy().into_owned(),
                mode,
                line: None,
                source: Source::Command,
            })
            .collect::<Vec<_>>()
    };
    let mut out = of(&r.reads, Mode::Read);
    out.extend(of(&r.writes, Mode::Write));
    out.extend(of(&r.listed, Mode::Listed));
    out
}

/// What a read, search or edit step's detail says of the files it was in (DIR: the session's folder, for a relative
/// path): a read with its first line, a search over a path listed, an edit with its first line if known.
pub fn touches_of_detail(d: &norn::write::work::StepDetail, dir: &Path) -> Vec<Touch> {
    let (mode, source) = match d.kind.as_deref() {
        Some("read") => (Mode::Read, Source::Acp),
        Some("search") => (Mode::Listed, Source::Acp),
        Some("edit") => (Mode::Edit, Source::Edit),
        _ => return Vec::new(),
    };
    let Some(p) = d.path.as_deref().filter(|p| !p.is_empty()) else {
        return Vec::new();
    };
    vec![Touch {
        file: place(dir, p),
        mode,
        line: d.line_start.and_then(|l| u32::try_from(l).ok()),
        source,
    }]
}

/// P in DIR as the model keys it: absolute, its links followed when it exists, else lexically clean.
pub fn place(dir: &Path, p: &str) -> RepoPath {
    let joined = dir.join(p);
    if let Ok(c) = std::fs::canonicalize(&joined) {
        return c.to_string_lossy().into_owned();
    }
    let mut out = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out.to_string_lossy().into_owned()
}

// ---- the shell ----

/// How long a file's changes gather before its `agent-presence` goes out (at most one per file per this).
pub const COALESCE: Duration = Duration::from_millis(100);

/// The most globs a shell step's command expands, per step.
const GLOB_CAP: usize = 200;

/// What one connection asked for.
#[derive(Debug, Default)]
struct Sub {
    roots: Vec<String>,
    files: BTreeSet<RepoPath>,
}

impl Sub {
    fn wants(&self, file: &str) -> bool {
        self.files.contains(file) || self.roots.iter().any(|r| under(file, r))
    }
}

/// A file or folder a caller names (an editor's buffer, a workspace root) as the model keys it: the model's files come
/// from [`place`], so one that exists is known by its true name (macOS's `/tmp/…` is `/private/tmp/…`).
pub fn true_name(asked: &str) -> RepoPath {
    place(Path::new("/"), asked)
}

/// Whether FILE is ROOT or under it, at a `/`.
fn under(file: &str, root: &str) -> bool {
    let root = root.trim_end_matches('/');
    file == root
        || file
            .strip_prefix(root)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// The hub's presence model, its subscribers and the files waiting to go out.
#[derive(Default)]
pub struct Live {
    model: Mutex<Presence>,
    subs: Mutex<BTreeMap<u64, Sub>>,
    pending: Mutex<BTreeSet<RepoPath>>,
    armed: AtomicBool,
    editors: OnceLock<Arc<crate::settings::agents::Editors>>,
    /// Each folder's checkout ([`checkout_of`]), at most [`CHECKOUTS_MAX`] (emptied when full).
    checkouts: Mutex<BTreeMap<PathBuf, Option<(PathBuf, String)>>>,
    /// Told the files each change touched, at once (the editors' buffer views, [`crate::editor`]).
    listener: OnceLock<Listener>,
}

/// What [`Live::on_change`] calls with the files a change touched.
pub type Listener = Arc<dyn Fn(&[RepoPath]) + Send + Sync>;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn wire(e: &Entry) -> PresenceEntry {
    PresenceEntry {
        session: e.session.clone(),
        file: e.file.clone(),
        mode: e.mode,
        line: e.line,
        line_end: e.line_end,
        col: e.col,
        source: e.source,
        step: e.step,
        at: e.at,
        live: e.live,
        tool_call: e.tool_call.clone(),
    }
}

/// The most folders [`Live`] remembers the checkout of.
const CHECKOUTS_MAX: usize = 4096;

/// The git checkout FILE (an absolute path, by its true name) is in: its top folder and its project id (16 hex digits
/// of the sha256 of the main checkout's real path, as [`crate::search::project::project_id`]; every linked worktree of
/// a repository has its main checkout's). Read from the `.git` entries alone: no git runs, in no agent's tree.
pub fn checkout_of(file: &Path) -> Option<(PathBuf, String)> {
    use sha2::{Digest, Sha256};
    use std::os::unix::ffi::OsStrExt;
    let mut dir = file.parent()?;
    loop {
        let dotgit = dir.join(".git");
        if let Ok(meta) = std::fs::symlink_metadata(&dotgit) {
            let common = if meta.is_dir() {
                dotgit
            } else {
                // a linked worktree (or a submodule): `gitdir: DIR`, whose `commondir` names the shared one
                let text = std::fs::read_to_string(&dotgit).ok()?;
                let gitdir = dir.join(text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim());
                match std::fs::read_to_string(gitdir.join("commondir")) {
                    Ok(c) => gitdir.join(c.trim()),
                    Err(_) => gitdir,
                }
            };
            let common = std::fs::canonicalize(common).ok()?;
            let main = match common.file_name() {
                Some(n) if n == ".git" => common.parent()?.to_path_buf(),
                _ => common,
            };
            let sum = Sha256::digest(main.as_os_str().as_bytes());
            let id = sum.iter().take(8).map(|b| format!("{b:02x}")).collect();
            return Some((dir.to_path_buf(), id));
        }
        dir = dir.parent()?;
    }
}

impl Live {
    /// EV into the model; the files it changed go out within [`COALESCE`], once each. The answer is those files (the
    /// Work map reads them at once).
    pub fn apply(self: &Arc<Self>, ev: PresenceEv) -> Vec<RepoPath> {
        let files: Vec<RepoPath> = lock(&self.model)
            .apply(ev)
            .into_iter()
            .map(|PresenceOut::Changed { file }| file)
            .collect();
        if !files.is_empty() && !lock(&self.subs).is_empty() {
            self.pending_flush(&files);
        }
        if !files.is_empty()
            && let Some(l) = self.listener.get()
        {
            l(&files);
        }
        files
    }

    /// L is told the files each change touches from now on (one listener; a second is ignored).
    pub fn on_change(&self, l: Listener) {
        let _ = self.listener.set(l);
    }

    /// Who is in each of FILES now (at the hub's time), file by file.
    pub fn now_in(&self, files: &[RepoPath]) -> Vec<(RepoPath, Vec<Entry>)> {
        let at = crate::clock::wall_secs();
        let model = lock(&self.model);
        files
            .iter()
            .map(|f| (f.clone(), model.now(f, at).into_iter().cloned().collect()))
            .collect()
    }

    /// Every file someone is in now, with its entries.
    pub fn all_now(&self) -> Vec<(RepoPath, Vec<Entry>)> {
        let files = lock(&self.model).files_under("/", crate::clock::wall_secs());
        self.now_in(&files)
    }

    fn pending_flush(self: &Arc<Self>, files: &[RepoPath]) {
        lock(&self.pending).extend(files.iter().cloned());
        if !self.armed.swap(true, Ordering::SeqCst) {
            let me = self.clone();
            crate::clock::spawn("presence:flush", async move {
                crate::clock::sleep(COALESCE).await;
                me.flush();
            });
        }
    }

    /// The waiting files' entries, each to the connections that asked for it.
    fn flush(&self) {
        // a change from here on arms the next flush
        self.armed.store(false, Ordering::SeqCst);
        let files = std::mem::take(&mut *lock(&self.pending));
        let Some(editors) = self.editors.get() else {
            return;
        };
        let at = crate::clock::wall_secs();
        for file in files {
            let conns: Vec<u64> = lock(&self.subs)
                .iter()
                .filter(|(_, s)| s.wants(&file))
                .map(|(c, _)| *c)
                .collect();
            if conns.is_empty() {
                continue;
            }
            let data = json!(self.file(&file, at));
            for conn in conns {
                if !editors.send_to(conn, "agent-presence", data.clone()) {
                    lock(&self.subs).remove(&conn);
                }
            }
        }
    }

    /// Who is in the file a caller named ASKED: looked up by its true name ([`true_name`]), the answer naming it as
    /// asked.
    fn file_asked(&self, asked: &str, at: f64) -> FilePresence {
        FilePresence {
            file: asked.to_string(),
            ..self.file(&true_name(asked), at)
        }
    }

    fn file(&self, file: &str, at: f64) -> FilePresence {
        let (rel, repo) = self.rel_and_repo(file).unzip();
        FilePresence {
            file: file.to_string(),
            rel,
            repo,
            entries: lock(&self.model)
                .now(file, at)
                .into_iter()
                .map(wire)
                .collect(),
        }
    }

    /// FILE (a true name) relative to its checkout's top, and the checkout's project id; none outside git.
    pub fn rel_and_repo(&self, file: &str) -> Option<(String, String)> {
        let path = Path::new(file);
        let dir = path.parent()?.to_path_buf();
        let known = lock(&self.checkouts).get(&dir).cloned();
        let found = match known {
            Some(f) => f,
            None => {
                let f = checkout_of(path);
                let mut all = lock(&self.checkouts);
                if all.len() >= CHECKOUTS_MAX {
                    all.clear();
                }
                all.insert(dir, f.clone());
                f
            }
        };
        let (top, repo) = found?;
        let rel = path.strip_prefix(&top).ok()?.to_string_lossy().into_owned();
        Some((rel, repo))
    }

    /// SESSION's running tool call TOOL_CALL is where UPDATE says; the files it changed, as [`Live::apply`].
    pub fn apply_live(
        self: &Arc<Self>,
        session: &str,
        tool_call: &str,
        update: LiveUpdate,
    ) -> Vec<RepoPath> {
        self.apply(PresenceEv::Live {
            session: session.into(),
            tool_call: tool_call.into(),
            update,
        })
    }

    /// SESSION's tool call TOOL_CALL ended: its step's entry CLOSED (none: failed or denied) replaces its live one.
    pub fn close_live(
        self: &Arc<Self>,
        session: &str,
        tool_call: &str,
        closed: Option<Entry>,
    ) -> Vec<RepoPath> {
        self.apply(PresenceEv::CloseLive {
            session: session.into(),
            tool_call: tool_call.into(),
            closed,
        })
    }

    /// See [`Presence::step_in`].
    pub fn step_in(&self, session: &str, file: &str) -> i64 {
        lock(&self.model).step_in(session, file)
    }

    /// SESSION's live entry under TOOL_CALL goes, the call left open (see [`PresenceEv::Withdraw`]).
    pub fn withdraw_live(self: &Arc<Self>, session: &str, tool_call: &str) -> Vec<RepoPath> {
        self.apply(PresenceEv::Withdraw {
            session: session.into(),
            tool_call: tool_call.into(),
        })
    }

    /// Connection CONN is gone: its subscriptions with it.
    pub fn gone(&self, conn: u64) {
        lock(&self.subs).remove(&conn);
    }

    /// The model rebuilt from the store, before the recorded sessions resume: their steps' read, search and edit
    /// details (a shell step's command is not kept, so its files come back only with its next step).
    pub async fn rebuild_from_store(&self, front: &Front) {
        let sessions = crate::agents::session::recorded(&front.core.agents).await;
        if sessions.is_empty() {
            return;
        }
        let ids: Vec<String> = sessions
            .iter()
            .map(|(s, _)| format!("session:{s}"))
            .collect();
        let rows = front
            .writer
            .db
            .read(move |c| {
                let mut q = c.prepare(
                    "select s.session, s.id, s.start, d.kind, d.path, d.line_start from step s \
                     join step_detail d on d.step = s.id where s.session = ?1 order by s.seq",
                )?;
                let mut out = Vec::new();
                for id in &ids {
                    let it = q.query_map([id], |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, f64>(2)?,
                            norn::write::work::StepDetail {
                                kind: r.get(3)?,
                                path: r.get(4)?,
                                line_start: r.get(5)?,
                                ..Default::default()
                            },
                        ))
                    })?;
                    for row in it {
                        out.push(row?);
                    }
                }
                Ok(out)
            })
            .await
            .unwrap_or_default();
        let dirs: BTreeMap<String, PathBuf> = sessions.into_iter().collect();
        let mut steps = Vec::new();
        let mut details = BTreeMap::new();
        for (session, id, at, d) in rows {
            let sid = session.trim_start_matches("session:").to_string();
            let Some(dir) = dirs.get(&sid) else { continue };
            details.insert(id, touches_of_detail(&d, dir));
            steps.push((sid, id, at));
        }
        *lock(&self.model) = Presence::rebuild(&steps, &details);
    }
}

/// The files a closed tool step was in: from its detail, and for a shell step from its COMMAND (in the session's
/// folder DIR; only paths inside it are kept). Blocking (the command's paths are looked up): off the async threads.
pub fn touches_of_step(
    detail: Option<&norn::write::work::StepDetail>,
    command: Option<&str>,
    dir: &Path,
) -> Vec<Touch> {
    let mut out = detail.map_or_else(Vec::new, |d| touches_of_detail(d, dir));
    if let Some(cmd) = command {
        let parsed = crate::work::shell_read::parse(cmd);
        let r = crate::work::shell_read::resolve(&parsed, dir, &[dir.to_path_buf()], GLOB_CAP);
        out.extend(touches_of_command(&r));
    }
    out
}

/// `agents/presence/subscribe`: CALLER's connection gets `agent-presence` for P's files from now on, and the answer is
/// who is in them now.
pub async fn subscribe(
    f: &Front,
    c: &Caller,
    p: PresenceSubscribe,
) -> Result<PresenceFiles, runstav::wire::Error> {
    let live = &f.core.presence;
    let _ = live.editors.set(f.editors.clone());
    let at = crate::clock::wall_secs();
    // the names asked, by their true names (the model's keys): a root's files are named as the model has them, a
    // single file as it was asked
    let files: Vec<FilePresence> = {
        let mut subs = lock(&live.subs);
        let s = subs.entry(c.conn_id).or_default();
        match (&p.workspace, &p.file) {
            (Some(ws), _) => {
                let roots: Vec<String> = ws
                    .roots
                    .iter()
                    .map(|r| true_name(&r.to_string_lossy()))
                    .collect();
                s.roots.extend(roots.iter().cloned());
                let mut all: BTreeSet<RepoPath> = BTreeSet::new();
                {
                    let model = lock(&live.model);
                    for r in &roots {
                        all.extend(model.files_under(r, at));
                    }
                }
                all.iter().map(|file| live.file(file, at)).collect()
            }
            (None, Some(file)) => {
                s.files.insert(true_name(file));
                vec![live.file_asked(file, at)]
            }
            (None, None) => Vec::new(),
        }
    };
    Ok(PresenceFiles {
        files: files
            .into_iter()
            .filter(|fp| !fp.entries.is_empty())
            .collect(),
    })
}

/// `agents/presence/get`: who is in P's file now, by whichever of its names P gives.
pub async fn get(
    f: &Front,
    _: &Caller,
    p: PresenceGet,
) -> Result<FilePresence, runstav::wire::Error> {
    Ok(f.core
        .presence
        .file_asked(&p.file, crate::clock::wall_secs()))
}

#[cfg(test)]
mod tests;
