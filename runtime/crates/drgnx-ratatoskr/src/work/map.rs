//! The Work map (docs/develop/hub.md, "The Work map"): the hub feeds `vegvisir` from its sources and sends each map
//! view, per (connection, view), what changed (`work/map/subscribe`, `work/map/set`, `work/map/close`; the event
//! `work-map`, by `Front::send_to` only).
//!
//! [`Coalescer`] is the pure part (design §11.3 step 5): per view, field changes go out at most once per
//! [`FIELDS_EVERY`]; a live arrival takes a free place and fades in, a departure fades out and leaves its place empty,
//! and nothing else moves; the accumulated structure reflows after a quiet second ([`QUIET`]: no change and no map key)
//! unless the reflow would move the selection's chain, which waits for the user; the user's own change relayouts at
//! once. It reads the hub's clock only as the [`CoIn::Now`] it is given. The rest of the file is the shell.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::agents::Editors;
use runstav::methods::agents::{SessionStatus, Snapshot};
use runstav::methods::timeline::StepClass;
use runstav::methods::work::{
    Machine, MapClose, MapDensity, MapFilters, MapFrame, MapSet, MapSubscribe, MapVersion,
    PresenceMode, WorkMap, Workspace,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::Duration;
use vegvisir::layout::{self, Layout};
use vegvisir::{
    CardFact, CardKind, Core, Delta, Density, Effect, Event, Filters, GraphFact, ItemId, Kind,
    MachineFact, Mode, PresenceEntry, PresenceFact, RefFact, SessionFact, State, StepFact, ViewKey,
    ViewOp, ViewState,
};

/// At most one delta per view this often (ms).
pub const FIELDS_EVERY: u64 = 100;
/// A quiet second: no change and no map key for this long (ms) reflows what accumulated.
pub const QUIET: u64 = 1000;

/// What one view's coalescing is told.
#[derive(Clone, Debug, PartialEq)]
pub enum CoIn {
    /// The hub's clock reads this many ms (a wake it asked for, or before any other input).
    Now(u64),
    /// The map core's delta for the view.
    Delta(Delta),
    /// The user changed the view (a filter, a collapse, the width, shown again).
    User,
    /// A map key (the selection moved).
    Key,
    /// The shell found that the quiet reflow would move the selection's chain: it waits for the user.
    Held,
}

/// What it asks the shell to do.
#[derive(Clone, Debug, PartialEq)]
pub enum CoOut {
    /// Send the gathered delta: its new items take a free place and fade in, its removed ones fade out.
    Send { delta: Delta },
    /// Lay the view out and send a full frame: the user's own change (`user`), or the quiet reflow, which the shell
    /// answers with [`CoIn::Held`] instead when it would move the selection's chain.
    Reflow { user: bool },
    /// Give me [`CoIn::Now`] at this time.
    Wake(u64),
}

/// One view's coalescing (see the module).
#[derive(Clone, Debug, Default)]
pub struct Coalescer {
    now: u64,
    pending: Option<Delta>,
    /// When the pending delta goes.
    due: Option<u64>,
    /// Structure changed since the last layout.
    reflow: bool,
    /// When the quiet reflow is due.
    quiet: Option<u64>,
    /// The quiet reflow would move the chain: wait for a key or the user.
    held: bool,
}

/// B merged into A: later wins for an item changed and removed.
fn merge(a: &mut Delta, b: Delta) {
    for id in b.changed {
        a.removed.retain(|r| *r != id);
        if !a.changed.contains(&id) {
            a.changed.push(id);
        }
    }
    for id in b.removed {
        a.changed.retain(|c| *c != id);
        if !a.removed.contains(&id) {
            a.removed.push(id);
        }
    }
    a.changed.sort();
    a.removed.sort();
    a.edges |= b.edges;
    a.structural |= b.structural;
    a.needs_you |= b.needs_you;
}

impl Coalescer {
    pub fn step(&mut self, ev: CoIn) -> Vec<CoOut> {
        let mut out = Vec::new();
        match ev {
            CoIn::Now(t) => {
                self.now = self.now.max(t);
                if self.due.is_some_and(|d| d <= self.now)
                    && let Some(delta) = self.pending.take()
                {
                    self.due = None;
                    out.push(CoOut::Send { delta });
                }
                if self.reflow && !self.held && self.quiet.is_some_and(|q| q <= self.now) {
                    self.quiet = None;
                    self.reflow = false;
                    out.push(CoOut::Reflow { user: false });
                }
            }
            CoIn::Delta(d) => {
                if d.structural {
                    self.reflow = true;
                }
                match &mut self.pending {
                    Some(p) => merge(p, d),
                    None => {
                        self.pending = Some(d);
                        let due = self.now + FIELDS_EVERY;
                        self.due = Some(due);
                        out.push(CoOut::Wake(due));
                    }
                }
                self.activity(&mut out);
            }
            CoIn::Key => {
                self.held = false;
                self.activity(&mut out);
            }
            CoIn::User => {
                self.pending = None;
                self.due = None;
                self.reflow = false;
                self.quiet = None;
                self.held = false;
                out.push(CoOut::Reflow { user: true });
            }
            CoIn::Held => {
                self.held = true;
                self.reflow = true;
            }
        }
        out
    }

    /// A change or a key: the quiet second starts again.
    fn activity(&mut self, out: &mut Vec<CoOut>) {
        if self.reflow && !self.held {
            let q = self.now + QUIET;
            self.quiet = Some(q);
            out.push(CoOut::Wake(q));
        }
    }
}

// ---- the shell ----

/// Where a session works, read from its folder's `.git` at first sight: the repository (named by its main tree's
/// folder), the tree the session is in, the branch checked out there.
#[derive(Clone, Debug, PartialEq)]
struct Place {
    repo: String,
    repo_root: PathBuf,
    top: PathBuf,
    /// The session's folder, canonical, and as it was given.
    cwd: PathBuf,
    given: PathBuf,
    branch: Option<String>,
}

/// The place of a session in CWD; none outside git.
fn place_of(given: &Path) -> Option<Place> {
    let cwd = std::fs::canonicalize(given).unwrap_or_else(|_| given.to_path_buf());
    let mut dir = cwd.as_path();
    loop {
        let dot = dir.join(".git");
        let (gitdir, common) = if dot.is_dir() {
            (dot.clone(), dot)
        } else if dot.is_file() {
            // a linked worktree: `gitdir: <main>/.git/worktrees/<name>`, whose `commondir` is the main `.git`
            let text = std::fs::read_to_string(&dot).ok()?;
            let gitdir = dir.join(text.trim().strip_prefix("gitdir:")?.trim());
            let common = std::fs::read_to_string(gitdir.join("commondir"))
                .map(|c| gitdir.join(c.trim()))
                .unwrap_or_else(|_| gitdir.clone());
            (gitdir, std::fs::canonicalize(&common).unwrap_or(common))
        } else {
            dir = dir.parent()?;
            continue;
        };
        let repo_root = match common.file_name() {
            Some(n) if n == ".git" => common.parent().unwrap_or(dir).to_path_buf(),
            _ => dir.to_path_buf(),
        };
        let branch = std::fs::read_to_string(gitdir.join("HEAD"))
            .ok()
            .and_then(|h| {
                h.trim()
                    .strip_prefix("ref: refs/heads/")
                    .map(str::to_string)
            });
        return Some(Place {
            repo: name_of(&repo_root),
            repo_root,
            top: dir.to_path_buf(),
            cwd: cwd.clone(),
            given: given.to_path_buf(),
            branch,
        });
    }
}

fn name_of(p: &Path) -> String {
    p.file_name()
        .map_or_else(|| "/".to_string(), |n| n.to_string_lossy().into_owned())
}

/// A file's map key, `REPO/PATH`: inside the session's tree against its repository, else inside one of ROOTS against
/// the root's name; none outside both.
fn file_key(abs: &str, place: Option<&Place>, roots: &[PathBuf]) -> Option<String> {
    let p = Path::new(abs);
    let join = |repo: &str, rel: &Path| format!("{repo}/{}", rel.to_string_lossy());
    if let Some(pl) = place {
        if let Ok(rel) = p.strip_prefix(&pl.top) {
            return Some(join(&pl.repo, rel));
        }
        if let Ok(rel) = p.strip_prefix(&pl.given) {
            let sub = pl.cwd.strip_prefix(&pl.top).unwrap_or(Path::new(""));
            return Some(join(&pl.repo, &sub.join(rel)));
        }
    }
    roots
        .iter()
        .find_map(|r| p.strip_prefix(r).ok().map(|rel| join(&name_of(r), rel)))
}

/// What the map keeps of a session.
struct Sess {
    snap: Snapshot,
    kids: Vec<crate::work::subagents::Child>,
    place: Option<Place>,
    seq: u64,
    state: State,
    since: u64,
}

impl Sess {
    /// Whether it works under one of ROOTS.
    fn under(&self, roots: &[PathBuf]) -> bool {
        let given = self.snap.cwd.as_deref().map(PathBuf::from);
        roots.iter().any(|r| {
            given.as_ref().is_some_and(|g| g.starts_with(r))
                || self
                    .place
                    .as_ref()
                    .is_some_and(|p| p.repo_root.starts_with(r) || p.cwd.starts_with(r))
        })
    }

    fn facts(&self) -> Vec<Event> {
        let s = &self.snap;
        let branch = self
            .place
            .as_ref()
            .and_then(|p| p.branch.as_ref().map(|b| format!("{}/{b}", p.repo)));
        let worktree = self
            .place
            .as_ref()
            .map(|p| p.top.to_string_lossy().into_owned());
        let usage = s.usage.as_ref();
        let context = usage
            .and_then(|u| Some((u.used?, u.size?)))
            .filter(|(_, size)| *size > 0.0)
            .map(|(used, size)| (used / size * 100.0).clamp(0.0, 100.0) as u8);
        let spend = usage
            .and_then(|u| u.cost.as_ref())
            .and_then(Value::as_f64)
            .map(|c| format!("${c:.2}"));
        let mut out = vec![Event::Session(SessionFact {
            id: s.id.clone(),
            name: s.name.clone().unwrap_or_else(|| s.id.clone()),
            model: s.profile.clone().unwrap_or_default(),
            state: self.state,
            since: self.since,
            seq: self.seq * 1000,
            task: s.task.clone(),
            manager: s.parent.clone(),
            branch,
            worktree,
            base: None,
            machine: None,
            spend,
            context,
            progress: None,
        })];
        // a subagent shares its parent's tree and branch (the core takes them from the parent) and its state
        for (i, k) in self.kids.iter().enumerate() {
            out.push(Event::Session(SessionFact {
                id: format!("{}/{}", s.id, k.parent_tool),
                name: k.name.clone(),
                model: String::new(),
                state: self.state,
                since: self.since,
                seq: self.seq * 1000 + i as u64 + 1,
                task: None,
                manager: None,
                branch: None,
                worktree: None,
                base: None,
                machine: None,
                spend: None,
                context: None,
                progress: None,
            }));
        }
        out
    }
}

/// A snapshot's state on the map.
fn state_of(s: &Snapshot) -> State {
    if !s.permissions.is_empty() {
        return State::NeedsYou;
    }
    if s.paused == Some(true) {
        return State::Paused;
    }
    match s.status {
        Some(SessionStatus::Starting) | None => State::Queued,
        Some(SessionStatus::Busy) => State::Running,
        Some(SessionStatus::Idle | SessionStatus::Waiting) => State::Waiting,
        Some(SessionStatus::Exited) => State::Finished,
    }
}

/// One workspace's model: the views of every connection that shows it share it.
struct Space {
    roots: Vec<PathBuf>,
    core: Core,
    /// `REPO/PATH` → the absolute files it stands for (a tree and its linked worktrees) → who is in each now.
    files: BTreeMap<String, BTreeMap<String, Vec<PresenceEntry>>>,
}

/// One view of one connection.
struct View {
    space: String,
    state: ViewState,
    shown: bool,
    selected: Option<ItemId>,
    version: u64,
    layout: Option<Layout>,
    /// The items the editor's frame holds.
    sent: BTreeSet<ItemId>,
    co: Coalescer,
}

#[derive(Default)]
struct Inner {
    spaces: BTreeMap<String, Space>,
    views: BTreeMap<ViewKey, View>,
    sessions: BTreeMap<String, Sess>,
    next_seq: u64,
    /// The cards open at the last read (a card gone from the list is settled).
    open_cards: BTreeSet<String>,
}

/// The hub's Work map (see the module).
#[derive(Default)]
pub struct Map {
    inner: Mutex<Inner>,
    /// Whether any view is open (read on every session snapshot).
    open: AtomicBool,
    editors: OnceLock<Arc<Editors>>,
    /// The front, for a session a step or presence names before its first snapshot reached the map.
    front: OnceLock<Weak<Front>>,
    origin: OnceLock<tokio::time::Instant>,
}

fn lock(m: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn minute() -> u64 {
    (crate::clock::wall_secs() / 60.0) as u64
}

fn no_view(view: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: format!("no map view {view:?} on this connection"),
        path: Some("view".into()),
    }
}

fn density(d: MapDensity) -> Density {
    match d {
        MapDensity::Compact => Density::Compact,
        MapDensity::Comfortable => Density::Comfortable,
        MapDensity::Roomy => Density::Roomy,
    }
}

fn filters(f: &MapFilters) -> Filters {
    Filters {
        focus: f.focus.clone().map(ItemId),
        overlaps: f.overlaps,
        finished: f.finished,
    }
}

fn mode(m: PresenceMode) -> Mode {
    match m {
        PresenceMode::Listed => Mode::Listed,
        PresenceMode::Read => Mode::Read,
        // an edit about to land changed nothing yet: the map shows the agent in the file, as a read
        PresenceMode::Pending => Mode::Read,
        PresenceMode::Write => Mode::Write,
        PresenceMode::Edit => Mode::Edit,
    }
}

fn machine_fact(m: &Machine) -> MachineFact {
    MachineFact {
        name: m.machine.clone(),
        slots: u32::try_from(m.slots.len()).unwrap_or(u32::MAX),
        used: u32::try_from(m.slots.iter().filter(|s| s.holder.is_some()).count())
            .unwrap_or(u32::MAX),
        reported: !m.local,
    }
}

/// The edges between items the frame holds.
fn edges_among(m: &vegvisir::Model, sent: &BTreeSet<ItemId>) -> Vec<Value> {
    m.edges()
        .into_iter()
        .filter(|e| sent.contains(&e.from) && sent.contains(&e.to))
        .map(|e| json!(e))
        .collect()
}

/// The machines' load, the strip's mission chips.
fn chips(m: &vegvisir::Model) -> Vec<Value> {
    m.items()
        .values()
        .filter(|it| it.kind == Kind::Machine)
        .map(|it| {
            let (used, total) = it.fields.slots.unwrap_or((0, 0));
            json!({"kind": "machine", "item": it.id, "label": it.label, "used": used, "total": total})
        })
        .collect()
}

/// The items a full frame of LAYOUT shows: those it places, and those of a collapsed layer (drawn as its count).
fn frame_items(m: &vegvisir::Model, v: &ViewState, l: &Layout) -> Vec<vegvisir::Item> {
    let narrowed = v.filters.focus.is_some() || v.filters.overlaps;
    m.items()
        .into_values()
        .filter(|it| {
            l.at.contains_key(&it.id)
                || (!narrowed
                    && (it.live || v.filters.finished)
                    && v.collapsed.contains(&it.kind.layer()))
        })
        .collect()
}

impl Map {
    /// Whether any map view is open.
    pub fn open(&self) -> bool {
        self.open.load(Ordering::Relaxed)
    }

    fn now_ms(&self) -> u64 {
        let origin = *self.origin.get_or_init(crate::clock::now);
        u64::try_from(crate::clock::now().duration_since(origin).as_millis()).unwrap_or(u64::MAX)
    }

    fn send(&self, conn: u64, data: &WorkMap) {
        if let Some(e) = self.editors.get() {
            e.send_to(conn, "work-map", json!(data));
        }
    }

    // ---- the sources ----

    /// A session's snapshot and its subagents, from its `agent` emit.
    pub fn session(self: &Arc<Self>, snap: &Snapshot, kids: &[crate::work::subagents::Child]) {
        if !self.open() {
            return;
        }
        let mut g = lock(&self.inner);
        let evs = Self::note_session(&mut g, snap, kids);
        let Some(evs) = evs else { return };
        self.feed_sessions(&mut g, &snap.id, evs);
    }

    /// The map's record of SNAP; the facts to feed when they changed.
    fn note_session(
        g: &mut Inner,
        snap: &Snapshot,
        kids: &[crate::work::subagents::Child],
    ) -> Option<Vec<Event>> {
        let state = state_of(snap);
        let now = minute();
        if !g.sessions.contains_key(&snap.id) {
            g.next_seq += 1;
            let place = snap.cwd.as_deref().and_then(|c| place_of(Path::new(c)));
            g.sessions.insert(
                snap.id.clone(),
                Sess {
                    snap: snap.clone(),
                    kids: Vec::new(),
                    place,
                    seq: g.next_seq,
                    state,
                    since: now,
                },
            );
        }
        let s = g.sessions.get_mut(&snap.id).expect("just noted");
        if s.state != state {
            s.state = state;
            s.since = now;
        }
        s.snap = snap.clone();
        s.kids = kids.to_vec();
        Some(s.facts())
    }

    /// The sessions of SIDS the map has not seen yet, noted from the hub's table (a step or presence can come before a
    /// session's first snapshot, which waits for the emit's throttle).
    fn ensure(self: &Arc<Self>, sids: &[&str]) {
        let missing: Vec<String> = {
            let g = lock(&self.inner);
            sids.iter()
                .filter(|s| !g.sessions.contains_key(**s))
                .map(|s| (*s).to_string())
                .collect()
        };
        if missing.is_empty() {
            return;
        }
        let Some(front) = self.front.get().and_then(Weak::upgrade) else {
            return;
        };
        let found: Vec<(Snapshot, Vec<crate::work::subagents::Child>)> = missing
            .iter()
            .filter_map(|id| front.core.agents.find(id).ok())
            .map(|s| (s.snapshot(), s.subagents()))
            .collect();
        let mut g = lock(&self.inner);
        for (snap, kids) in found {
            if !g.sessions.contains_key(&snap.id)
                && let Some(evs) = Self::note_session(&mut g, &snap, &kids)
            {
                self.feed_sessions(&mut g, &snap.id, evs);
            }
        }
    }

    /// EVS (session SID's facts) into every workspace it works in.
    fn feed_sessions(self: &Arc<Self>, g: &mut Inner, sid: &str, evs: Vec<Event>) {
        let spaces: Vec<String> = g
            .spaces
            .iter()
            .filter(|(_, sp)| g.sessions.get(sid).is_some_and(|s| s.under(&sp.roots)))
            .map(|(k, _)| k.clone())
            .collect();
        for k in spaces {
            self.feed(g, &k, evs.clone());
        }
    }

    /// Session SID closed timeline step STEP of CLASS, at AT (the hub's seconds).
    pub fn step(self: &Arc<Self>, sid: &str, step: i64, class: &StepClass, at: f64) {
        if !self.open() {
            return;
        }
        let class = json!(class).as_str().unwrap_or("tool").to_string();
        let ev = Event::Step(StepFact {
            session: sid.to_string(),
            step,
            class,
            minute: (at / 60.0) as u64,
            conclusion: None,
        });
        self.ensure(&[sid]);
        let mut g = lock(&self.inner);
        self.feed_sessions(&mut g, sid, vec![ev]);
    }

    /// Session SID took a step snapshot: its worktree's changed files against its base (`work::edits::changed`) as
    /// the worktree's changed set, keyed `REPO/PATH` through the session's tree.
    pub async fn edited(self: &Arc<Self>, sid: &str) {
        if !self.open() {
            return;
        }
        let Some(front) = self.front.get().and_then(Weak::upgrade) else {
            return;
        };
        let (Some(wt), Ok(Some(changed))) = (
            front.core.agents.worktree(sid),
            crate::work::edits::changed(&front, sid).await,
        ) else {
            return;
        };
        self.ensure(&[sid]);
        let mut g = lock(&self.inner);
        let Some(place) = g.sessions.get(sid).and_then(|s| s.place.clone()) else {
            return;
        };
        let files = changed
            .files
            .iter()
            .filter_map(|c| {
                let abs = wt.join(&c.path);
                file_key(&abs.to_string_lossy(), Some(&place), &[]).map(|k| (k, (c.plus, c.minus)))
            })
            .collect();
        let ev = Event::Changed {
            worktree: place.top.to_string_lossy().into_owned(),
            base: changed.base,
            files,
        };
        self.feed_sessions(&mut g, sid, vec![ev]);
    }

    /// Who is in each of FILES now (absolute paths), from the presence model.
    pub fn presence(self: &Arc<Self>, files: &[(String, Vec<crate::work::presence::Entry>)]) {
        if !self.open() || files.is_empty() {
            return;
        }
        let sids: Vec<&str> = files
            .iter()
            .flat_map(|(_, es)| es.iter().map(|e| e.session.as_str()))
            .collect();
        self.ensure(&sids);
        let mut g = lock(&self.inner);
        let keys: Vec<String> = g.spaces.keys().cloned().collect();
        for k in keys {
            let evs = Self::presence_events(&mut g, &k, files);
            self.feed(&mut g, &k, evs);
        }
    }

    /// The presence facts of FILES for workspace K: each file's key, and who is in it across the files it stands for.
    fn presence_events(
        g: &mut Inner,
        k: &str,
        files: &[(String, Vec<crate::work::presence::Entry>)],
    ) -> Vec<Event> {
        let Inner {
            spaces, sessions, ..
        } = g;
        let Some(sp) = spaces.get_mut(k) else {
            return Vec::new();
        };
        let mut touched = BTreeSet::new();
        for (abs, entries) in files {
            // the file's key comes from the sessions in it (their trees), else from the workspace's roots
            let place = entries
                .iter()
                .find_map(|e| sessions.get(&e.session).and_then(|s| s.place.as_ref()));
            let Some(key) = file_key(abs, place, &sp.roots) else {
                continue;
            };
            let mine: Vec<PresenceEntry> = entries
                .iter()
                .filter(|e| sessions.get(&e.session).is_some_and(|s| s.under(&sp.roots)))
                .map(|e| PresenceEntry {
                    session: e.session.clone(),
                    mode: mode(e.mode),
                    line: e.line,
                })
                .collect();
            let slot = sp.files.entry(key.clone()).or_default();
            if mine.is_empty() {
                slot.remove(abs);
            } else {
                slot.insert(abs.clone(), mine);
            }
            touched.insert(key);
        }
        touched
            .into_iter()
            .map(|key| {
                let entries: Vec<PresenceEntry> = sp
                    .files
                    .get(&key)
                    .map(|m| m.values().flatten().cloned().collect())
                    .unwrap_or_default();
                if entries.is_empty() {
                    sp.files.remove(&key);
                }
                Event::Presence(PresenceFact { file: key, entries })
            })
            .collect()
    }

    /// The machine registry changed.
    pub fn machines(self: &Arc<Self>, list: &[Machine]) {
        if !self.open() {
            return;
        }
        let facts: Vec<MachineFact> = list.iter().map(machine_fact).collect();
        let mut g = lock(&self.inner);
        let keys: Vec<String> = g.spaces.keys().cloned().collect();
        for k in keys {
            self.feed(&mut g, &k, vec![Event::Machines(facts.clone())]);
        }
    }

    /// The store's records read again (asks, specs, plans, tasks, their links, open cards) and each workspace's
    /// "based on" pairs.
    fn store(
        self: &Arc<Self>,
        records: Vec<Event>,
        cards: Vec<Card>,
        refs: BTreeMap<String, Vec<RefFact>>,
    ) {
        let mut g = lock(&self.inner);
        let mut evs = records;
        evs.extend(Self::card_events(&mut g, cards));
        let keys: Vec<String> = g.spaces.keys().cloned().collect();
        for k in keys {
            let mut mine = evs.clone();
            if let Some(r) = refs.get(&k) {
                mine.push(Event::Refs(r.clone()));
            }
            self.feed(&mut g, &k, mine);
        }
    }

    /// Open cards `(id, job, kind, title)` as card facts, each about the agents of its job; those open before and gone
    /// now as settled.
    fn card_events(g: &mut Inner, cards: Vec<Card>) -> Vec<Event> {
        let now: BTreeSet<String> = cards.iter().map(|c| c.0.clone()).collect();
        let mut out: Vec<Event> = cards
            .into_iter()
            .map(|(id, job, kind, title)| {
                let about = g
                    .sessions
                    .values()
                    .filter(|s| s.snap.job.as_deref() == Some(job.as_str()))
                    .map(|s| format!("agent:{}", s.snap.id))
                    .collect();
                Event::Card(CardFact {
                    id,
                    kind: card_kind(&kind),
                    about,
                    text: title,
                    open: true,
                })
            })
            .collect();
        for gone in g.open_cards.difference(&now) {
            out.push(Event::Card(CardFact {
                id: gone.clone(),
                kind: CardKind::Question,
                about: Vec::new(),
                text: String::new(),
                open: false,
            }));
        }
        g.open_cards = now;
        out
    }

    /// The clock's minute.
    fn tick(self: &Arc<Self>) {
        let ev = Event::Tick { minute: minute() };
        let mut g = lock(&self.inner);
        let keys: Vec<String> = g.spaces.keys().cloned().collect();
        for k in keys {
            self.feed(&mut g, &k, vec![ev.clone()]);
        }
    }

    // ---- the core and the views ----

    /// EVS into workspace K's core; each effect to its view.
    fn feed(self: &Arc<Self>, g: &mut Inner, k: &str, evs: Vec<Event>) {
        let mut effects = Vec::new();
        let Some(sp) = g.spaces.get_mut(k) else {
            return;
        };
        for ev in evs {
            effects.extend(sp.core.step(ev));
        }
        let now = self.now_ms();
        for e in effects {
            match e {
                Effect::Delta { view, delta } => {
                    self.coalesce(g, &view, Some(CoIn::Delta(delta)), now)
                }
                Effect::Relayout { view } => self.coalesce(g, &view, Some(CoIn::User), now),
                Effect::Stale { view } => self.stale(g, &view),
            }
        }
    }

    /// One input to VIEW's coalescing, after the clock's reading; what it asks is done.
    fn coalesce(self: &Arc<Self>, g: &mut Inner, key: &ViewKey, input: Option<CoIn>, now: u64) {
        let Some(v) = g.views.get_mut(key) else {
            return;
        };
        let mut outs = v.co.step(CoIn::Now(now));
        if let Some(i) = input {
            outs.extend(v.co.step(i));
        }
        self.outs(g, key, outs, now);
    }

    fn outs(self: &Arc<Self>, g: &mut Inner, key: &ViewKey, outs: Vec<CoOut>, now: u64) {
        for o in outs {
            match o {
                CoOut::Wake(at) => self.wake(key.clone(), at.saturating_sub(now)),
                CoOut::Send { delta } => self.send_delta(g, key, delta),
                CoOut::Reflow { user: false } if self.chain_moves(g, key) => {
                    let more = g
                        .views
                        .get_mut(key)
                        .map(|v| v.co.step(CoIn::Held))
                        .unwrap_or_default();
                    self.outs(g, key, more, now);
                }
                CoOut::Reflow { .. } => self.send_full(g, key),
            }
        }
    }

    /// Give VIEW's coalescing the clock's reading in MS.
    fn wake(self: &Arc<Self>, key: ViewKey, ms: u64) {
        let me = self.clone();
        crate::clock::spawn("map:wake", async move {
            crate::clock::sleep(Duration::from_millis(ms)).await;
            let mut g = lock(&me.inner);
            let now = me.now_ms();
            me.coalesce(&mut g, &key, None, now);
        });
    }

    /// Whether laying VIEW out again would move an item of its selection's chain.
    fn chain_moves(&self, g: &Inner, key: &ViewKey) -> bool {
        let Some(v) = g.views.get(key) else {
            return false;
        };
        let (Some(sel), Some(prev), Some(sp)) = (&v.selected, &v.layout, g.spaces.get(&v.space))
        else {
            return false;
        };
        let m = sp.core.model();
        let chain = m.chain(sel);
        let next = layout::layout(m, &v.state, Some(prev));
        std::iter::once(sel)
            .chain(&chain.up)
            .chain(&chain.down)
            .any(|id| prev.at.get(id) != next.at.get(id))
    }

    /// A hidden view's frame went stale.
    fn stale(&self, g: &mut Inner, key: &ViewKey) {
        let Some(v) = g.views.get_mut(key) else {
            return;
        };
        v.version += 1;
        let data = WorkMap {
            view: key.view.clone(),
            version: v.version,
            base: v.version - 1,
            full: false,
            changed: Vec::new(),
            removed: Vec::new(),
            entered: Vec::new(),
            places: None,
            edges: None,
            layout: None,
            needs_you: None,
            chips: None,
            stale: Some(true),
        };
        self.send(key.conn, &data);
    }

    /// The gathered DELTA to VIEW: arrivals at free places, departures leaving theirs empty, nothing else moved.
    fn send_delta(&self, g: &mut Inner, key: &ViewKey, delta: Delta) {
        let Inner { spaces, views, .. } = g;
        let Some(v) = views.get_mut(key) else {
            return;
        };
        let (Some(sp), Some(prev)) = (spaces.get(&v.space), v.layout.as_ref()) else {
            return;
        };
        if !v.shown {
            return;
        }
        let m = sp.core.model();
        let narrowed = v.state.filters.focus.is_some() || v.state.filters.overlaps;
        let mut items = Vec::new();
        let mut new = Vec::new();
        for id in &delta.changed {
            let Some(it) = m.item(id) else { continue };
            let visible =
                (it.live || v.state.filters.finished) && (it.kind != Kind::File || it.shared);
            if v.sent.contains(id) || (!narrowed && visible) {
                if !v.sent.contains(id) {
                    new.push(id.clone());
                }
                items.push(it);
            }
        }
        let gone: Vec<ItemId> = delta
            .removed
            .iter()
            .filter(|id| v.sent.contains(*id))
            .cloned()
            .collect();
        if items.is_empty() && gone.is_empty() && !delta.edges && !delta.needs_you {
            return;
        }
        let next = layout::place_live(&v.state, prev, &new, &gone);
        let entered: Vec<ItemId> = new
            .iter()
            .filter(|id| next.at.contains_key(*id))
            .cloned()
            .collect();
        let places = (!entered.is_empty()).then(|| {
            json!(
                entered
                    .iter()
                    .map(|id| (
                        id.as_str(),
                        json!({"rect": next.at[id], "form": next.form.get(id)})
                    ))
                    .collect::<BTreeMap<_, _>>()
            )
        });
        v.sent.extend(new);
        for id in &gone {
            v.sent.remove(id);
        }
        v.layout = Some(next);
        v.version += 1;
        let machines = items.iter().any(|it| it.kind == Kind::Machine);
        let data = WorkMap {
            view: key.view.clone(),
            version: v.version,
            base: v.version - 1,
            full: false,
            changed: items.iter().map(|it| json!(it)).collect(),
            removed: gone.iter().map(|id| id.0.clone()).collect(),
            entered: entered.iter().map(|id| id.0.clone()).collect(),
            places,
            edges: (delta.edges || !entered.is_empty() || !gone.is_empty())
                .then(|| edges_among(m, &v.sent)),
            layout: None,
            needs_you: delta
                .needs_you
                .then(|| m.needs_you().iter().map(|n| json!(n)).collect()),
            chips: machines.then(|| chips(m)),
            stale: None,
        };
        self.send(key.conn, &data);
    }

    /// VIEW laid out again: a full frame.
    fn send_full(&self, g: &mut Inner, key: &ViewKey) {
        let Inner { spaces, views, .. } = g;
        let Some(v) = views.get_mut(key) else {
            return;
        };
        let Some(sp) = spaces.get(&v.space) else {
            return;
        };
        if !v.shown {
            return;
        }
        let m = sp.core.model();
        let frame = Self::frame(m, v);
        let data = WorkMap {
            view: key.view.clone(),
            version: v.version,
            base: v.version - 1,
            full: true,
            changed: frame.items,
            removed: Vec::new(),
            entered: Vec::new(),
            places: None,
            edges: Some(frame.edges),
            layout: Some(frame.layout),
            needs_you: Some(frame.needs_you),
            chips: Some(frame.chips),
            stale: None,
        };
        self.send(key.conn, &data);
    }

    /// V laid out again from model M: its next version's full frame (V's layout, frame and version follow it).
    fn frame(m: &vegvisir::Model, v: &mut View) -> MapFrame {
        let l = layout::layout(m, &v.state, v.layout.as_ref());
        let items = frame_items(m, &v.state, &l);
        v.sent = items.iter().map(|it| it.id.clone()).collect();
        v.version += 1;
        let frame = MapFrame {
            version: v.version,
            items: items.iter().map(|it| json!(it)).collect(),
            edges: edges_among(m, &v.sent),
            layout: json!(l),
            needs_you: m.needs_you().iter().map(|n| json!(n)).collect(),
            chips: chips(m),
        };
        v.layout = Some(l);
        frame
    }

    /// Connection CONN is gone: its views with it.
    pub fn gone(&self, conn: u64) {
        let mut g = lock(&self.inner);
        let keys: Vec<ViewKey> = g.views.keys().filter(|k| k.conn == conn).cloned().collect();
        for k in keys {
            Self::close_view(&mut g, &k);
        }
        self.open.store(!g.views.is_empty(), Ordering::Relaxed);
    }

    fn close_view(g: &mut Inner, key: &ViewKey) -> bool {
        let Some(v) = g.views.remove(key) else {
            return false;
        };
        if let Some(sp) = g.spaces.get_mut(&v.space) {
            sp.core
                .step(Event::View(ViewOp::Close { view: key.clone() }));
        }
        // a workspace no view shows is dropped
        if !g.views.values().any(|o| o.space == v.space) {
            g.spaces.remove(&v.space);
        }
        if g.views.is_empty() {
            g.sessions.clear();
        }
        true
    }
}

/// `work/map/subscribe`: VIEW of CALLER's connection opens (again) on its workspace; the answer is its full frame.
pub async fn subscribe(f: &Front, c: &Caller, p: MapSubscribe) -> Result<MapFrame, Error> {
    let map = &f.core.map;
    let _ = map.editors.set(f.editors.clone());
    let roots: Vec<PathBuf> = p
        .workspace
        .roots
        .iter()
        .flat_map(|r| {
            let canon = std::fs::canonicalize(r).ok().filter(|c| c != r);
            std::iter::once(r.clone()).chain(canon)
        })
        .collect();
    // the seed: the store's records and refs, the machines, the sessions and who is in which file now
    let (records, cards) = read_store(f).await;
    let refs = refs_of(f, &p.workspace).await;
    let machines = crate::work::machines::list_now(f);
    let sessions: Vec<(Snapshot, Vec<crate::work::subagents::Child>)> = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| (s.snapshot(), s.subagents()))
        .collect();
    let files = f.core.presence.all_now();
    let key = ViewKey {
        conn: c.conn_id,
        view: p.view.clone(),
    };
    let state = ViewState {
        width_units: p.width_units,
        density: density(p.density),
        filters: filters(&p.filters),
        collapsed: p.collapsed.iter().copied().collect(),
    };
    let mut g = lock(&map.inner);
    map.open.store(true, Ordering::Relaxed);
    Map::close_view(&mut g, &key);
    let ws = p.workspace.id.clone();
    let sp = g.spaces.entry(ws.clone()).or_insert_with(|| Space {
        roots: Vec::new(),
        core: Core::new(),
        files: BTreeMap::new(),
    });
    sp.roots = roots;
    let mut seed = records;
    seed.extend(Map::card_events(&mut g, cards));
    seed.push(Event::Refs(refs));
    seed.push(Event::Machines(machines.iter().map(machine_fact).collect()));
    for (snap, kids) in &sessions {
        if let Some(evs) = Map::note_session(&mut g, snap, kids)
            && g.sessions[&snap.id].under(&g.spaces[&ws].roots)
        {
            seed.extend(evs);
        }
    }
    seed.extend(Map::presence_events(&mut g, &ws, &files));
    map.feed(&mut g, &ws, seed);
    let sp = g.spaces.get_mut(&ws).expect("the view's workspace");
    sp.core.step(Event::View(ViewOp::Open {
        view: key.clone(),
        state: state.clone(),
        shown: true,
    }));
    let mut v = View {
        space: ws,
        state,
        shown: true,
        selected: p.selected.map(ItemId),
        version: 0,
        layout: None,
        sent: BTreeSet::new(),
        co: Coalescer::default(),
    };
    let frame = Map::frame(sp.core.model(), &mut v);
    g.views.insert(key, v);
    Ok(frame)
}

/// `work/map/set`: VIEW changes; the user's own change relayouts at once (a `work-map` full frame); the answer is the
/// view's version after it.
pub fn set(f: &Front, c: &Caller, p: MapSet) -> Result<MapVersion, Error> {
    let map = &f.core.map;
    let key = ViewKey {
        conn: c.conn_id,
        view: p.view.clone(),
    };
    let mut g = lock(&map.inner);
    let Some(v) = g.views.get_mut(&key) else {
        return Err(no_view(&p.view));
    };
    let mut state = v.state.clone();
    if let Some(fl) = &p.filters {
        state.filters = filters(fl);
    }
    if let Some(cl) = &p.collapsed {
        state.collapsed = cl.iter().copied().collect();
    }
    if let Some(w) = p.width_units {
        state.width_units = w;
    }
    if let Some(d) = p.density {
        state.density = density(d);
    }
    let selected = p.selected.clone().map(ItemId);
    if selected.is_some() {
        v.selected = selected;
    }
    let space = v.space.clone();
    let mut ops = Vec::new();
    if state != v.state {
        v.state = state.clone();
        ops.push(ViewOp::Set {
            view: key.clone(),
            state,
        });
    }
    if let Some(shown) = p.shown
        && shown != v.shown
    {
        v.shown = shown;
        // a hidden view drops what it gathered; shown again, it gets one full frame
        v.co = Coalescer::default();
        ops.push(ViewOp::Shown {
            view: key.clone(),
            shown,
        });
    }
    let now = map.now_ms();
    let f_map = map.clone();
    let mut effects = Vec::new();
    if let Some(sp) = g.spaces.get_mut(&space) {
        for op in ops {
            effects.extend(sp.core.step(Event::View(op)));
        }
    }
    // one full frame for the user's change, however many parts it had
    let mut relayout = false;
    for e in effects {
        match e {
            Effect::Relayout { view } if view == key => relayout = true,
            Effect::Delta { view, delta } => {
                f_map.coalesce(&mut g, &view, Some(CoIn::Delta(delta)), now)
            }
            Effect::Relayout { view } => f_map.coalesce(&mut g, &view, Some(CoIn::User), now),
            Effect::Stale { view } => f_map.stale(&mut g, &view),
        }
    }
    if relayout {
        f_map.coalesce(&mut g, &key, Some(CoIn::User), now);
    } else if p.selected.is_some() {
        f_map.coalesce(&mut g, &key, Some(CoIn::Key), now);
    }
    Ok(MapVersion {
        version: g.views.get(&key).map_or(0, |v| v.version),
    })
}

/// `work/map/close`: VIEW of CALLER's connection ends.
pub fn close(f: &Front, c: &Caller, p: MapClose) -> Result<bool, Error> {
    let map = &f.core.map;
    let mut g = lock(&map.inner);
    let closed = Map::close_view(
        &mut g,
        &ViewKey {
            conn: c.conn_id,
            view: p.view,
        },
    );
    map.open.store(!g.views.is_empty(), Ordering::Relaxed);
    Ok(closed)
}

/// A card's kind on the map.
fn card_kind(k: &str) -> CardKind {
    match k {
        "permission" => CardKind::Permission,
        "push" | "tag" => CardKind::Push,
        "review" | "rate" | "sign-off" | "gate" => CardKind::SignOff,
        "supervisor" => CardKind::Supervisor,
        "budget" => CardKind::Budget,
        "clash" => CardKind::Clash,
        "proposal" => CardKind::Proposal,
        _ => CardKind::Question,
    }
}

/// An open card: id, job, kind, title.
type Card = (String, String, String, String);

/// The store's records the map shows: asks, specs, plans and their tasks, `asked` and `derives`; and the open cards.
async fn read_store(f: &Front) -> (Vec<Event>, Vec<Card>) {
    f.writer
        .db
        .read(|c| {
            let mut out = Vec::new();
            let strip = |id: &str| id.split_once(':').map_or(id, |(_, k)| k).to_string();
            let mut plan_of: BTreeMap<String, String> = BTreeMap::new();
            let mut links = Vec::new();
            {
                let mut q = c.prepare(
                    "select a.id, l.kind, b.id from link l join entity a on a.n = l.src \
                     join entity b on b.n = l.dst where l.tx_to = ?1 \
                     and l.kind in ('asked', 'derives', 'parent_of') \
                     and a.retired_tx is null and b.retired_tx is null",
                )?;
                let rows = q.query_map([urdr::graph::schema::SENTINEL], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })?;
                for row in rows {
                    let (a, kind, b) = row?;
                    if kind == "parent_of" && a.starts_with("plan:") && b.starts_with("task:") {
                        plan_of.insert(b, strip(&a));
                    } else {
                        links.push((a, kind, b));
                    }
                }
            }
            {
                let mut q = c.prepare(
                    "select id, kind, coalesce(title, ''), coalesce(status, ''), \
                     coalesce(json_extract(data, '$.text'), title, '') from entity \
                     where retired_tx is null and kind in ('ask', 'spec', 'plan', 'task') order by n",
                )?;
                let rows = q.query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                })?;
                for (rank, row) in rows.enumerate() {
                    let (id, kind, title, status, text) = row?;
                    out.push(match kind.as_str() {
                        "ask" => Event::Graph(GraphFact::Ask {
                            key: strip(&id),
                            text,
                        }),
                        "spec" => Event::Graph(GraphFact::Spec {
                            id: strip(&id),
                            title,
                        }),
                        "plan" => Event::Graph(GraphFact::Plan {
                            id: strip(&id),
                            title,
                            rank: rank as u64,
                            progress: None,
                        }),
                        _ => {
                            let Some(plan) = plan_of.get(&id) else { continue };
                            Event::Graph(GraphFact::Task {
                                id: strip(&id),
                                plan: plan.clone(),
                                title,
                                done: status == "done",
                            })
                        }
                    });
                }
            }
            for (a, kind, b) in links {
                out.push(Event::Graph(match kind.as_str() {
                    "asked" => GraphFact::Asked {
                        ask: strip(&a),
                        to: match b.strip_prefix("session:") {
                            Some(s) => format!("agent:{s}"),
                            None => b,
                        },
                    },
                    _ => GraphFact::Derives {
                        plan: strip(&a),
                        spec: strip(&b),
                    },
                }));
            }
            let mut cards = Vec::new();
            let mut q = c.prepare(
                "select id, coalesce(job, ''), coalesce(kind, ''), coalesce(title, '') from card \
                 where state = 'open' order by id",
            )?;
            let rows = q.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?.to_string(),
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?;
            for row in rows {
                cards.push(row?);
            }
            Ok((out, cards))
        })
        .await
        .unwrap_or_default()
}

/// WS's "based on" pairs, as the core reads them.
async fn refs_of(f: &Front, ws: &Workspace) -> Vec<RefFact> {
    crate::work::bases::ancestry(f, ws)
        .await
        .into_iter()
        .map(|(child, parent)| RefFact {
            branch: format!("{}/{}", name_of(&child.repo), child.branch),
            based_on: Some(format!("{}/{}", name_of(&parent.repo), parent.branch)),
            merged: false,
        })
        .collect()
}

/// The map's background: the store's records read again after each write while a map is open, and the clock's minute.
pub async fn run(front: Arc<Front>) {
    let _ = front.core.map.front.set(Arc::downgrade(&front));
    let ticks = front.clone();
    crate::clock::spawn("map:ticks", async move {
        loop {
            crate::clock::sleep(Duration::from_secs(60)).await;
            if ticks.core.map.open() {
                ticks.core.map.tick();
            }
        }
    });
    let signals = front.writer.signals.clone();
    loop {
        signals.map.notified().await;
        if !front.core.map.open() {
            continue;
        }
        let (records, cards) = read_store(&front).await;
        let spaces: Vec<(String, Vec<PathBuf>)> = {
            let g = lock(&front.core.map.inner);
            g.spaces
                .iter()
                .map(|(k, sp)| (k.clone(), sp.roots.clone()))
                .collect()
        };
        let mut refs = BTreeMap::new();
        for (k, roots) in spaces {
            let ws = Workspace {
                id: k.clone(),
                roots,
            };
            refs.insert(k, refs_of(&front, &ws).await);
        }
        front.core.map.store(records, cards, refs);
    }
}

#[cfg(test)]
mod tests;
