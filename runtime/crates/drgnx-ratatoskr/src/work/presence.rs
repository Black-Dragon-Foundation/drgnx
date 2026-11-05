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

use crate::dispatch::Caller;
use crate::front::Front;
use runstav::methods::work::{
    FilePresence, PresenceEntry, PresenceFiles, PresenceGet, PresenceMode as Mode,
    PresenceSource as Source, PresenceSubscribe,
};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Duration;

/// `presence-stale-after`: an entry older than this is history, unless it is its session's latest.
pub const STALE_AFTER: f64 = 120.0;

/// An absolute path in one of the workspace's repositories.
pub type RepoPath = String;

/// One session in one file.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub session: String,
    pub file: RepoPath,
    pub mode: Mode,
    pub line: Option<u32>,
    pub source: Source,
    pub step: i64,
    pub at: f64,
}

/// A file a step was in, and how.
#[derive(Clone, Debug, PartialEq)]
pub struct Touch {
    pub file: RepoPath,
    pub mode: Mode,
    pub line: Option<u32>,
    pub source: Source,
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
}

impl Presence {
    pub fn new() -> Presence {
        Presence::default()
    }

    pub fn apply(&mut self, ev: PresenceEv) -> Vec<PresenceOut> {
        let mut changed: BTreeSet<RepoPath> = BTreeSet::new();
        match ev {
            PresenceEv::Step {
                session,
                step,
                at,
                files,
            } => {
                if self.ended.contains(&session) {
                    return Vec::new();
                }
                let before = self.latest(&session).map(|e| e.file.clone());
                let mine = self.by_session.entry(session.clone()).or_default();
                for t in files {
                    let e = Entry {
                        session: session.clone(),
                        file: t.file,
                        mode: t.mode,
                        line: t.line,
                        source: t.source,
                        step,
                        at,
                    };
                    let newer = mine.get(&e.file).is_none_or(|old| rank(&e) > rank(old));
                    if newer {
                        changed.insert(e.file.clone());
                        mine.insert(e.file.clone(), e);
                    }
                }
                // the session's latest moved: the file it left may read differently now
                let after = self.latest(&session).map(|e| e.file.clone());
                if before != after {
                    changed.extend(before);
                    changed.extend(after);
                }
            }
            PresenceEv::SessionEnd { session } => {
                if self.ended.insert(session.clone())
                    && let Some(mine) = self.by_session.get(&session)
                {
                    changed.extend(mine.keys().cloned());
                }
            }
        }
        changed
            .into_iter()
            .map(|file| PresenceOut::Changed { file })
            .collect()
    }

    /// SESSION's latest entry: of its highest step, the strongest mode.
    fn latest(&self, session: &str) -> Option<&Entry> {
        self.by_session
            .get(session)?
            .values()
            .max_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| b.file.cmp(&a.file)))
    }

    /// Who is in FILE at AT: each live session's entry there that is younger than [`STALE_AFTER`] or is the session's
    /// latest, by session.
    pub fn now(&self, file: &str, at: f64) -> Vec<&Entry> {
        self.by_session
            .iter()
            .filter(|(s, _)| !self.ended.contains(*s))
            .filter_map(|(s, files)| {
                let e = files.get(file)?;
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
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn wire(e: &Entry) -> PresenceEntry {
    PresenceEntry {
        session: e.session.clone(),
        file: e.file.clone(),
        mode: e.mode,
        line: e.line,
        source: e.source,
        step: e.step,
        at: e.at,
    }
}

impl Live {
    /// EV into the model; the files it changed go out within [`COALESCE`], once each.
    pub fn apply(self: &Arc<Self>, ev: PresenceEv) {
        let outs = lock(&self.model).apply(ev);
        if outs.is_empty() || lock(&self.subs).is_empty() {
            return;
        }
        lock(&self.pending).extend(outs.into_iter().map(|PresenceOut::Changed { file }| file));
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

    fn file(&self, file: &str, at: f64) -> FilePresence {
        FilePresence {
            file: file.to_string(),
            entries: lock(&self.model)
                .now(file, at)
                .into_iter()
                .map(wire)
                .collect(),
        }
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
    let files: Vec<RepoPath> = {
        let mut subs = lock(&live.subs);
        let s = subs.entry(c.conn_id).or_default();
        match (&p.workspace, &p.file) {
            (Some(ws), _) => {
                let roots: Vec<String> = ws
                    .roots
                    .iter()
                    .map(|r| r.to_string_lossy().into_owned())
                    .collect();
                s.roots.extend(roots.iter().cloned());
                let model = lock(&live.model);
                let mut all: BTreeSet<RepoPath> = BTreeSet::new();
                for r in &roots {
                    all.extend(model.files_under(r, at));
                }
                all.into_iter().collect()
            }
            (None, Some(file)) => {
                s.files.insert(file.clone());
                vec![file.clone()]
            }
            (None, None) => Vec::new(),
        }
    };
    Ok(PresenceFiles {
        files: files
            .iter()
            .map(|file| live.file(file, at))
            .filter(|fp| !fp.entries.is_empty())
            .collect(),
    })
}

/// `agents/presence/get`: who is in P's file now.
pub async fn get(
    f: &Front,
    _: &Caller,
    p: PresenceGet,
) -> Result<FilePresence, runstav::wire::Error> {
    Ok(f.core.presence.file(&p.file, crate::clock::wall_secs()))
}

#[cfg(test)]
mod tests;
