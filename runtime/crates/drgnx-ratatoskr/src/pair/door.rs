//! The door (docs/develop/hub.md, "Pair mode"): the one way a paired chat's write reaches your checkout.
//!
//! - **A write** ([`Door::write`]): the session's gate ([`super::gate`]), then its door: paired (`chat.project-edit`
//!   allow), then the editor gets `pair-apply` with the write's edits ([`super::writes`]) and a relative `ttl_ms` the
//!   editor counts from its arrival.  One file's writes go one at a time, in order ([`FileQueue`]); the caller waits
//!   on its own task, so a session's reader loop never waits on an editor.
//! - **The verdict is the editor's.** `pair/answer` (from the connection the write went to) ends a write; the hub's
//!   own timer, at `ttl_ms` plus [`MARGIN`] with no answer, only sends `pair-reconcile`, which the editor answers from
//!   what it applied.  An editor that goes away with a write in flight leaves it unknown ("read it with read_file to
//!   see"), never refused.
//! - **A read** ([`Door::read`]): `read_file` and a chat's `fs/read_text_file` pass [`super::read_gate`]; an editor
//!   connected is asked for the buffer's text (`pair-read`, unsaved edits included, with its version), else the disk
//!   is read.  The read is recorded per (session, file): a whole-file write of an existing file needs one the editor
//!   served.
//! - **Refusals** name what to do; two refused writes of one file by a session within [`REFUSAL_WINDOW`] say "wait
//!   for the user or ask them", and the session's snapshot says `waiting {file, lines}` until a write of it applies.
//! - **Which editor** ([`super::open_set`]): a write goes to the editor that has the file open as a normal buffer; a
//!   large or remote buffer refuses it, a file an editor had when it went away refuses "the editor is away", and a
//!   file no editor has goes to the disk ([`super::disk`]: atomic, over the session's read only, recorded in the
//!   history as the agent's).  The hub never writes the disk behind an open file.
//! - **The toggle, the wheel and the matrix** ([`Door::toggle`], [`Door::hold`], [`Door::recheck`]): pair off, the user
//!   holding the wheel, or a matrix change that makes `chat.project-edit` never ([`follow_matrix`]) closes the
//!   session's door at once: its writes not yet sent are refused, the editor drops those it holds (`pair-drop`, each
//!   answered `dropped`), and later ones are refused.  Nothing of the session's turn is cancelled.
//! - **Presence** ([`crate::work::presence`]): a write the editor holds is the session's live `pending` entry on the
//!   lines it will change (found in the session's served read, else the file); applied, it becomes the session's
//!   `edit` entry on the lines its new text covers, at the session's step in that file.  Any other end leaves nothing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use norn::matrix::{Action, Effective, Verdict, decide};
use runstav::methods::agents::Waiting;
use runstav::methods::pair::{
    PairAnswer, PairApply, PairDrop, PairRead, PairReadAnswer, PairReconcile, PairResult,
};
use runstav::types::AbsPath;
use serde_json::json;
use tokio::sync::oneshot;

use super::open_set::{OpenEv, OpenSet, Route};
use super::writes::{Ev, FileQueue, Outcome, REREAD, Served, WriteId, plan_edit, plan_whole};
use super::{Refusal, gate, read_gate};
use crate::settings::agents::Editors;
use crate::work::edit_lines::{EditRange, of_diff};
use crate::work::presence::{CallStatus, Entry, Live, LiveUpdate, true_name};
use runstav::methods::work::{PresenceMode, PresenceSource};

/// How long a write may wait in the editor's queue, counted by the editor from its arrival.
pub const TTL_MS: u64 = 2000;

/// What the hub waits past `ttl_ms` before it asks the editor what became of a write.
pub const MARGIN: Duration = Duration::from_millis(1000);

/// How long a read waits for the editor's text.
pub const READ_WAIT: Duration = Duration::from_secs(5);

/// Two refusals of one file within this window: the agent is told to wait for the user or ask.
pub const REFUSAL_WINDOW: Duration = Duration::from_secs(60);

/// What the drgnx edit tools answer while the chat is not paired.
pub const PAIR_OFF: &str = "pair mode is off; ask the user to turn it on";

/// What a write answers when the editor that had the file went away.
pub const EDITOR_AWAY: &str = "the editor is away";

/// What a chat's writes answer once the user turned pair off for it.
pub const OFF_BY_USER: &str = "pair mode was turned off by the user";

/// What a paired chat's writes answer once the matrix made its `chat.project-edit` never (a preset or a cell changed).
pub const NEVER_NOW: &str =
    "pair mode ended: the matrix's chat.project-edit is now never for this chat; ask the user";

/// What a write of a session whose wheel the user holds answers.
pub const HELD: &str = "the user holds the wheel; wait until they give it back";

/// What the user is told when turning pair on where the matrix says never.
pub const NEVER_HERE: &str =
    "pair mode is not allowed for this chat: the matrix's chat.project-edit is never for it";

/// What the agent is told, queued, when the user turns pair off for it.
pub const OFF_NOTE: &str = "[drgnx: the user turned pair mode off for this chat. Your edits of the project are \
    refused until they turn it on again; nothing you were doing was cancelled.]";

/// A write's form.
#[derive(Clone, Debug, PartialEq)]
pub enum WriteKind {
    /// `edit_file {old, new}`.
    Edit { old: String, new: String },
    /// `write_file {content}` and ACP `fs/write_text_file`.
    Whole { content: String },
}

/// The text of a refusal by the editor: REASON (its code, or its own words) and the user's LINES.
pub fn refused_text(reason: &str, lines: Option<[u64; 2]>) -> String {
    let at = |l: Option<[u64; 2]>| match l {
        Some([a, b]) if a == b => format!("line {a}"),
        Some([a, b]) => format!("lines {a}–{b}"),
        None => "those lines".to_string(),
    };
    match reason {
        "overlap" | "guard" => format!(
            "the user is editing {}; read it with read_file and change it outside them, or ask",
            at(lines)
        ),
        "no-match" => format!("old is not in the editor's text: {REREAD}"),
        "several" => {
            format!("old matches more than once in the editor's text; give more of it: {REREAD}")
        }
        "gap" => format!("the editor no longer has the changes since your read: {REREAD}"),
        "changed-on-disk" => {
            format!("the file changed on disk under the user's unsaved edits: {REREAD}")
        }
        "read-only" => "the buffer is read-only in the editor".to_string(),
        "locked" => "another Emacs has this file locked".to_string(),
        "not-open" => "not open in the editor; ask the user to open it".to_string(),
        "pair-off" => OFF_BY_USER.to_string(),
        "held" => HELD.to_string(),
        "never" => NEVER_NOW.to_string(),
        other => other.to_string(),
    }
}

/// A write waiting for the editor.
struct Pending {
    file: PathBuf,
    session: String,
    conn: u64,
    apply: PairApply,
    /// The editor's answer, once it came (for the verdict's text).
    answer: Option<PairAnswer>,
    reply: Option<oneshot::Sender<(Outcome, Option<PairAnswer>)>>,
    /// The new text of a whole-file write: the session's read once it applies.
    whole: Option<String>,
}

/// A chat's pair state.
#[derive(Default)]
struct SessionPair {
    /// Its `chat.project-edit` verdict when last seen.
    cell: Option<Verdict>,
    /// The user's toggle; none: as the cell says (allow: paired).
    on: Option<bool>,
    /// The user holds its wheel.
    held: bool,
}

impl SessionPair {
    fn paired(&self) -> bool {
        match self.cell {
            None | Some(Verdict::Never) => false,
            Some(c) => self.on.unwrap_or(c == Verdict::Allow),
        }
    }
}

#[derive(Default)]
struct St {
    sessions: HashMap<String, SessionPair>,
    open: OpenSet,
    served: HashMap<(String, PathBuf), Served>,
    files: HashMap<PathBuf, FileQueue>,
    ordinals: HashMap<PathBuf, u64>,
    pending: HashMap<WriteId, Pending>,
    /// Reads waiting for an editor's text: the connection asked, and where its answer goes.
    reads: HashMap<u64, (u64, oneshot::Sender<PairReadAnswer>)>,
    refusals: HashMap<(String, PathBuf), Vec<tokio::time::Instant>>,
    waiting: HashMap<String, Waiting>,
    /// The user's own writes waiting for their turn in a file's queue ([`Door::user_turn`]): told when it comes.
    turns: HashMap<WriteId, oneshot::Sender<()>>,
}

/// The queue's name for the user's own writes (the Search view's): never a chat's, so no door closes on them.
const USER: &str = "user:search";

/// The user's turn in one file's queue ([`Door::user_turn`]): the writes after it wait until it is dropped.
pub struct UserTurn {
    door: Arc<Door>,
    file: PathBuf,
    id: WriteId,
}

impl Drop for UserTurn {
    fn drop(&mut self) {
        let mut st = lock(&self.door.st);
        let fx = step(
            &mut st,
            &self.file,
            Ev::Answer {
                id: self.id,
                outcome: Outcome::Applied,
            },
        );
        self.door.run(&mut st, &self.file, fx);
    }
}

/// The hub's door for paired chats: one per hub.
pub struct Door {
    editors: Arc<Editors>,
    /// The presence model the writes show in.
    presence: Arc<Live>,
    st: Mutex<St>,
    next: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Door {
    pub fn new(editors: Arc<Editors>, presence: Arc<Live>) -> Arc<Door> {
        Arc::new(Door {
            editors,
            presence,
            st: Mutex::default(),
            next: AtomicU64::new(1),
        })
    }

    fn id(&self) -> u64 {
        self.next.fetch_add(1, Ordering::Relaxed)
    }

    /// Whether SESSION, with the cells EFF, is paired now: the user's toggle, else `chat.project-edit` allow; never
    /// while the cell is never.
    pub fn paired(&self, session: &str, eff: &Effective) -> bool {
        let cell = decide(eff, Action::ChatProjectEdit, None);
        let mut st = lock(&self.st);
        let s = st.sessions.entry(session.to_string()).or_default();
        s.cell = Some(cell);
        s.paired()
    }

    /// Chat SESSION in a project started with CELL as its `chat.project-edit` (its snapshot's `paired` from now on).
    pub fn started(&self, session: &str, cell: Verdict) {
        lock(&self.st)
            .sessions
            .entry(session.to_string())
            .or_default()
            .cell = Some(cell);
    }

    /// SESSION's snapshot `paired`: none for a session that is no chat in a project.
    pub fn paired_now(&self, session: &str) -> Option<bool> {
        lock(&self.st)
            .sessions
            .get(session)
            .map(SessionPair::paired)
    }

    /// SESSION's `waiting {file, lines}`: two refusals of one file, until a write of it applies.
    pub fn waiting(&self, session: &str) -> Option<Waiting> {
        lock(&self.st).waiting.get(session).cloned()
    }

    /// The editor's open files changed (`pair/open`, `pair/closed`, `pair/open-set`).
    pub fn open_ev(&self, ev: OpenEv) -> bool {
        lock(&self.st).open.step(ev);
        true
    }

    /// The user's toggle: pair ON or off for SESSION (cells EFF).  On needs `chat.project-edit` not never; off closes
    /// the door at once ([`Door::close`]).
    pub fn toggle(
        self: &Arc<Self>,
        session: &str,
        on: bool,
        eff: &Effective,
    ) -> Result<(), Refusal> {
        let cell = decide(eff, Action::ChatProjectEdit, None);
        if on && cell == Verdict::Never {
            return Err(Refusal(NEVER_HERE.into()));
        }
        {
            let mut st = lock(&self.st);
            let s = st.sessions.entry(session.to_string()).or_default();
            s.cell = Some(cell);
            s.on = Some(on);
        }
        if !on {
            self.close(session, OFF_BY_USER, "pair-off");
        }
        Ok(())
    }

    /// The user took (HELD) or gave back SESSION's wheel: while held its door is closed ([`Door::close`]).
    pub fn hold(self: &Arc<Self>, session: &str, held: bool) {
        lock(&self.st)
            .sessions
            .entry(session.to_string())
            .or_default()
            .held = held;
        if held {
            self.close(session, HELD, "held");
        }
    }

    /// The matrix may have changed: SESSION's `chat.project-edit` is decided again from EFF.  A paired session whose
    /// cell became never closes ([`Door::close`], reason `never`): its writes not yet sent are refused and the editor
    /// drops those it holds.  True when it closed.
    pub fn recheck(self: &Arc<Self>, session: &str, eff: &Effective) -> bool {
        let cell = decide(eff, Action::ChatProjectEdit, None);
        let closed = {
            let mut st = lock(&self.st);
            let Some(s) = st.sessions.get_mut(session) else {
                return false;
            };
            let was = s.paired();
            s.cell = Some(cell);
            was && cell == Verdict::Never
        };
        if closed {
            self.close(session, NEVER_NOW, "never");
        }
        closed
    }

    /// The sessions the door holds as paired now: the ones a matrix change may close.
    pub fn paired_sessions(&self) -> Vec<String> {
        lock(&self.st)
            .sessions
            .iter()
            .filter(|(_, s)| s.paired())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// SESSION's door closes: its writes not yet sent are refused with WHY, and each editor holding one of its writes
    /// is told to drop them (`pair-drop`, answered `dropped` with REASON, each the editor's verdict).
    fn close(self: &Arc<Self>, session: &str, why: &str, reason: &str) {
        let mut st = lock(&self.st);
        let files: Vec<PathBuf> = st.files.keys().cloned().collect();
        for f in files {
            let fx = step(
                &mut st,
                &f,
                Ev::Close {
                    session: session.to_string(),
                    why: why.to_string(),
                },
            );
            self.run(&mut st, &f, fx);
        }
        let mut conns: Vec<u64> = st
            .pending
            .values()
            .filter(|p| p.session == session)
            .map(|p| p.conn)
            .collect();
        conns.sort_unstable();
        conns.dedup();
        drop(st);
        let ev = json!(PairDrop {
            session: session.to_string(),
            reason: reason.to_string(),
        });
        for c in conns {
            self.editors.send_to(c, "pair-drop", ev.clone());
        }
    }

    /// Where a write of FILE goes now.
    pub fn route(&self, file: &Path) -> Route {
        lock(&self.st).open.route(&file.to_path_buf())
    }

    /// The user's write of FILE (the Search view's) takes its turn in FILE's queue: it comes once every write before it
    /// (a paired chat's, another of the user's) has ended, and the writes after it wait until the turn is dropped.  So
    /// drgnx's own writers never interleave on one file.
    pub async fn user_turn(self: &Arc<Self>, file: &Path) -> UserTurn {
        let id = self.id();
        let (tx, rx) = oneshot::channel();
        {
            let mut st = lock(&self.st);
            st.turns.insert(id, tx);
            let fx = step(
                &mut st,
                file,
                Ev::Submit {
                    id,
                    session: USER.to_string(),
                },
            );
            self.run(&mut st, file, fx);
        }
        let turn = UserTurn {
            door: self.clone(),
            file: file.to_path_buf(),
            id,
        };
        let _ = rx.await;
        turn
    }

    /// SESSION's read of PATH in the checkout ROOT (cells EFF): the editor's text and version when an editor has it,
    /// else the disk's; recorded as the session's read of that file.
    pub async fn read(
        self: &Arc<Self>,
        session: &str,
        root: &Path,
        eff: &Effective,
        path: &str,
    ) -> Result<Served, Refusal> {
        let real = read_gate(eff, root, Path::new(path))?;
        // the editor's text when a normal buffer has the file; the disk's otherwise
        let from_editor = match self.route(&real) {
            Route::Editor(conn) => self.ask_editor(conn, &real).await?,
            Route::Refused(_) | Route::Disk => None,
        };
        let served = match from_editor {
            Some(s) => s,
            None => Served {
                text: tokio::fs::read_to_string(&real)
                    .await
                    .map_err(|e| Refusal(format!("{path}: {e}")))?,
                version: None,
            },
        };
        lock(&self.st)
            .served
            .insert((session.to_string(), real), served.clone());
        Ok(served)
    }

    /// The editor CONN's text of FILE: none when it does not have the file open (the disk is read then).
    async fn ask_editor(&self, conn: u64, file: &Path) -> Result<Option<Served>, Refusal> {
        let req = self.id();
        let (tx, rx) = oneshot::channel();
        lock(&self.st).reads.insert(req, (conn, tx));
        let ev = PairRead {
            req,
            file: abs(file)?,
        };
        if !self.editors.send_to(conn, "pair-read", json!(ev)) {
            lock(&self.st).reads.remove(&req);
            return Ok(None);
        }
        let got = crate::clock::timeout(READ_WAIT, rx).await;
        lock(&self.st).reads.remove(&req);
        match got {
            Ok(Ok(a)) => match (a.error, a.text) {
                (Some(e), _) if e.as_str() == "not-open" => Ok(None),
                (Some(e), _) => Err(Refusal(refused_text(e.as_str(), None))),
                (None, Some(text)) => Ok(Some(Served {
                    text,
                    version: a.version,
                })),
                (None, None) => Ok(None),
            },
            _ => Err(Refusal(
                "the editor did not answer the read; try again".to_string(),
            )),
        }
    }

    /// Editor connection CONN's `pair/read-answer`: true when a read was waiting for it from CONN.
    pub fn read_answer(&self, conn: u64, a: PairReadAnswer) -> bool {
        let mut st = lock(&self.st);
        if st.reads.get(&a.req).is_none_or(|(c, _)| *c != conn) {
            return false;
        }
        match st.reads.remove(&a.req) {
            Some((_, tx)) => tx.send(a).is_ok(),
            None => false,
        }
    }

    /// SESSION's write KIND of PATH in the checkout ROOT (cells EFF): the agent's answer once the editor has given
    /// its own, or why it was refused.
    pub async fn write(
        self: &Arc<Self>,
        session: &str,
        root: &Path,
        eff: &Effective,
        path: &str,
        kind: WriteKind,
    ) -> Result<String, Refusal> {
        self.write_with(session, 0, root, eff, path, kind, None)
            .await
    }

    /// [`Door::write`] of SESSION's STEP (the editor's change carries it into the edit history), with RECORD told a
    /// write to a file open nowhere before it lands on disk (the session's history, so the watcher does not count it
    /// as an outside edit).
    #[allow(clippy::too_many_arguments)]
    pub async fn write_with(
        self: &Arc<Self>,
        session: &str,
        step: i64,
        root: &Path,
        eff: &Effective,
        path: &str,
        kind: WriteKind,
        record: Option<super::disk::Record>,
    ) -> Result<String, Refusal> {
        if lock(&self.st).sessions.get(session).is_some_and(|s| s.held) {
            return Err(Refusal(HELD.into()));
        }
        if !self.paired(session, eff) {
            // the gate's own refusal (a never cell, a protected path) says more than "off"
            gate(eff, root, Path::new(path))?;
            return Err(Refusal(PAIR_OFF.into()));
        }
        let real = gate(eff, root, Path::new(path))?;
        let conn = match self.route(&real) {
            Route::Editor(conn) => conn,
            Route::Refused(why) => return Err(Refusal(why.into())),
            // open nowhere: the disk, atomically, over the session's read
            Route::Disk => return self.disk(session, root, real, kind, record).await,
        };
        let (rx, id, range) = {
            let mut st = lock(&self.st);
            // the door may have closed since the checks above: decided again under the lock the close takes
            match st.sessions.get(session) {
                Some(s) if s.held => return Err(Refusal(HELD.into())),
                Some(s) if s.on == Some(false) => return Err(Refusal(OFF_BY_USER.into())),
                Some(s) if !s.paired() => return Err(Refusal(PAIR_OFF.into())),
                _ => {}
            }
            let range = lines_of(
                st.served.get(&(session.to_string(), real.clone())),
                &real,
                &kind,
            );
            let (planned, whole) = match kind {
                WriteKind::Edit { old, new } => (plan_edit(&old, &new)?, None),
                WriteKind::Whole { content } => {
                    // the base must be the editor's text: a read from disk cannot be shifted over the user's edits
                    let served = st
                        .served
                        .get(&(session.to_string(), real.clone()))
                        .filter(|s| s.version.is_some());
                    (plan_whole(served, real.exists(), &content)?, Some(content))
                }
            };
            let id = self.id();
            let ordinal = {
                let o = st.ordinals.entry(real.clone()).or_default();
                *o += 1;
                *o
            };
            let floor = st
                .served
                .iter()
                .filter(|((_, f), _)| *f == real)
                .filter_map(|(_, s)| s.version)
                .min();
            let apply = PairApply {
                write: id,
                session: session.to_string(),
                step,
                ordinal,
                file: abs(&real)?,
                version: planned.version,
                floor,
                edits: planned.edits,
                ttl_ms: TTL_MS,
            };
            let (tx, rx) = oneshot::channel();
            st.pending.insert(
                id,
                Pending {
                    file: real.clone(),
                    session: session.to_string(),
                    conn,
                    apply,
                    answer: None,
                    reply: Some(tx),
                    whole,
                },
            );
            // pending in the presence feed before the editor is sent the write
            self.presence.apply_live(
                session,
                &presence_call(id),
                LiveUpdate {
                    path: true_name(&real.to_string_lossy()),
                    mode: PresenceMode::Pending,
                    line: range.map(|r| r.line),
                    line_end: range.map(|r| r.line_end),
                    col: range.map(|r| r.col),
                    status: CallStatus::InProgress,
                    source: PresenceSource::Edit,
                    at: crate::clock::wall_secs(),
                },
            );
            let fx = st.files.entry(real.clone()).or_default().step(Ev::Submit {
                id,
                session: session.to_string(),
            });
            self.run(&mut st, &real, fx);
            (rx, id, range)
        };
        let (outcome, answer) = rx.await.unwrap_or((Outcome::Lost, None));
        self.landed(session, id, &real, range, outcome == Outcome::Applied);
        self.verdict(session, &real, outcome, answer)
    }

    /// SESSION's write KIND of REAL, a file no editor has open, in the checkout ROOT: on disk ([`super::disk::write`]);
    /// the new text is the session's read from then on.
    async fn disk(
        self: &Arc<Self>,
        session: &str,
        root: &Path,
        real: PathBuf,
        kind: WriteKind,
        record: Option<super::disk::Record>,
    ) -> Result<String, Refusal> {
        let served = {
            let st = lock(&self.st);
            match st.sessions.get(session) {
                Some(s) if s.held => return Err(Refusal(HELD.into())),
                Some(s) if s.on == Some(false) => return Err(Refusal(OFF_BY_USER.into())),
                Some(s) if !s.paired() => return Err(Refusal(PAIR_OFF.into())),
                _ => {}
            }
            st.served.get(&(session.to_string(), real.clone())).cloned()
        };
        let (root, file) = (root.to_path_buf(), real.clone());
        let text = crate::clock::blocking(move || {
            super::disk::write(&root, &file, served.as_ref(), &kind, record)
        })
        .await
        .map_err(|e| Refusal(format!("the write did not run: {e}")))??;
        lock(&self.st).served.insert(
            (session.to_string(), real),
            Served {
                text,
                version: None,
            },
        );
        Ok("written to the file on disk (no editor has it open)".to_string())
    }

    /// Write ID of SESSION to FILE ended: its pending entry goes; APPLIED, the session is in FILE on RANGE, editing.
    fn landed(
        &self,
        session: &str,
        id: WriteId,
        file: &Path,
        range: Option<EditRange>,
        applied: bool,
    ) {
        let file = true_name(&file.to_string_lossy());
        let closed = applied.then(|| Entry {
            session: session.to_string(),
            step: self.presence.step_in(session, &file),
            file,
            mode: PresenceMode::Edit,
            line: range.map(|r| r.line),
            line_end: range.map(|r| r.line_end),
            col: range.map(|r| r.col),
            source: PresenceSource::Edit,
            at: crate::clock::wall_secs(),
            live: false,
            tool_call: None,
        });
        self.presence
            .close_live(session, &presence_call(id), closed);
    }

    /// The effects FX of FILE's queue, done under the door's lock (sends only queue a line; a timer is a task).
    fn run(self: &Arc<Self>, st: &mut St, file: &Path, fx: Vec<Ev>) {
        let mut work: Vec<Ev> = fx.into_iter().rev().collect();
        while let Some(ev) = work.pop() {
            let more = match ev {
                Ev::Send { id } => {
                    if let Some(tx) = st.turns.remove(&id) {
                        // the user's turn: its writer is told; one that gave up waiting ends it at once
                        if tx.send(()).is_ok() {
                            continue;
                        }
                        work.extend(
                            step(
                                st,
                                file,
                                Ev::Answer {
                                    id,
                                    outcome: Outcome::Applied,
                                },
                            )
                            .into_iter()
                            .rev(),
                        );
                        continue;
                    }
                    let Some(p) = st.pending.get(&id) else {
                        continue;
                    };
                    if self.editors.send_to(p.conn, "pair-apply", json!(p.apply)) {
                        let me = self.clone();
                        let f = file.to_path_buf();
                        crate::clock::spawn("pair:expiry", async move {
                            crate::clock::sleep(Duration::from_millis(TTL_MS) + MARGIN).await;
                            me.expired(&f, id);
                        });
                        Vec::new()
                    } else {
                        // never delivered, so never applied
                        step(
                            st,
                            file,
                            Ev::Answer {
                                id,
                                outcome: Outcome::Refused(EDITOR_AWAY.into()),
                            },
                        )
                    }
                }
                Ev::Reconcile { id } => {
                    let Some(p) = st.pending.get(&id) else {
                        continue;
                    };
                    let ev = PairReconcile {
                        write: id,
                        file: p.apply.file.clone(),
                    };
                    if self.editors.send_to(p.conn, "pair-reconcile", json!(ev)) {
                        Vec::new()
                    } else {
                        step(
                            st,
                            file,
                            Ev::Answer {
                                id,
                                outcome: Outcome::Lost,
                            },
                        )
                    }
                }
                Ev::Verdict { id, outcome } => {
                    if let Some(mut p) = st.pending.remove(&id) {
                        let key = (p.session.clone(), p.file.clone());
                        if outcome == Outcome::Applied {
                            // the session's read is what it wrote now, at the editor's version after it; an edit
                            // leaves no text the hub knows, so the old read goes
                            let version = p.answer.as_ref().and_then(|a| a.version);
                            match p.whole.take() {
                                Some(text) if version.is_some() => {
                                    st.served.insert(key, Served { text, version });
                                }
                                _ => {
                                    st.served.remove(&key);
                                }
                            }
                        }
                        if let Some(tx) = p.reply.take() {
                            let _ = tx.send((outcome, p.answer.take()));
                        }
                    }
                    Vec::new()
                }
                Ev::Submit { .. } | Ev::Answer { .. } | Ev::Expired { .. } | Ev::Close { .. } => {
                    Vec::new()
                }
            };
            work.extend(more.into_iter().rev());
        }
    }

    /// The hub's timer for write ID of FILE.
    fn expired(self: &Arc<Self>, file: &Path, id: WriteId) {
        let mut st = lock(&self.st);
        if !st.files.contains_key(file) {
            return;
        }
        let fx = step(&mut st, file, Ev::Expired { id });
        self.run(&mut st, file, fx);
    }

    /// Editor connection CONN's `pair/answer`: true when its write was waiting for that connection's answer.
    pub fn answer(self: &Arc<Self>, conn: u64, a: PairAnswer) -> bool {
        let mut st = lock(&self.st);
        let Some(p) = st.pending.get_mut(&a.write) else {
            return false;
        };
        if p.conn != conn {
            return false;
        }
        let file = p.file.clone();
        let outcome = match a.result {
            PairResult::Applied => Outcome::Applied,
            PairResult::Refused => Outcome::Refused(
                a.reason
                    .as_ref()
                    .map_or("refused", |r| r.as_str())
                    .to_string(),
            ),
            PairResult::Dropped => Outcome::Dropped,
        };
        let id = a.write;
        p.answer = Some(a);
        let fx = step(&mut st, &file, Ev::Answer { id, outcome });
        self.run(&mut st, &file, fx);
        true
    }

    /// Editor connection CONN is gone: the files it had open are away until an editor opens them again, its writes in
    /// flight are unknown, the reads waiting for it give up.
    pub fn editor_gone(self: &Arc<Self>, conn: u64) {
        let mut st = lock(&self.st);
        st.open.step(OpenEv::Gone { conn });
        st.reads.retain(|_, (c, _)| *c != conn);
        let lost: Vec<(WriteId, PathBuf)> = st
            .pending
            .iter()
            .filter(|(id, p)| {
                p.conn == conn && st.files.get(&p.file).and_then(FileQueue::in_flight) == Some(**id)
            })
            .map(|(id, p)| (*id, p.file.clone()))
            .collect();
        for (id, file) in lost {
            let fx = step(
                &mut st,
                &file,
                Ev::Answer {
                    id,
                    outcome: Outcome::Lost,
                },
            );
            self.run(&mut st, &file, fx);
        }
    }

    /// The agent's answer for OUTCOME of SESSION's write of FILE (the editor's ANSWER, when it gave one).
    fn verdict(
        &self,
        session: &str,
        file: &Path,
        outcome: Outcome,
        answer: Option<PairAnswer>,
    ) -> Result<String, Refusal> {
        let text = match outcome {
            Outcome::Applied => {
                let mut st = lock(&self.st);
                st.refusals
                    .remove(&(session.to_string(), file.to_path_buf()));
                if st
                    .waiting
                    .get(session)
                    .is_some_and(|w| Path::new(&w.file) == file)
                {
                    st.waiting.remove(session);
                }
                let a = answer.as_ref();
                return Ok(match (
                    a.and_then(|a| a.saved),
                    a.and_then(|a| a.not_saved.as_ref()),
                ) {
                    (_, Some(why)) => format!("applied in the editor; not saved: {}", why.as_str()),
                    (Some(true), _) => "applied in the editor and saved".to_string(),
                    (Some(false), _) => "applied in the editor; the file on disk has neither the user's unsaved \
                                         edits nor yours until the user saves"
                        .to_string(),
                    (None, None) => "applied in the editor".to_string(),
                });
            }
            // the door closed before it was sent: not the agent's mistake, not counted
            Outcome::Refused(why) if why == OFF_BY_USER || why == HELD || why == NEVER_NOW => {
                return Err(Refusal(why));
            }
            Outcome::Refused(reason) => {
                let lines = answer.as_ref().and_then(|a| a.lines);
                refused_text(&reason, lines)
            }
            // dropped unapplied (its time ran out, the user turned pair off or took the wheel, the matrix made it
            // never): no refusal of the agent's text, so not counted towards "wait for the user"
            Outcome::Dropped => {
                return Err(Refusal(
                    answer
                        .as_ref()
                        .and_then(|a| a.reason.as_ref())
                        .filter(|r| matches!(r.as_str(), "pair-off" | "held" | "never"))
                        .map_or_else(
                            || {
                                "the editor did not get to it in time; nothing of it was applied: try again"
                                    .to_string()
                            },
                            |r| refused_text(r.as_str(), None),
                        ),
                ));
            }
            Outcome::Lost => {
                return Err(Refusal(
                    "the editor went away before it answered; read it with read_file to see whether your \
                     change is there"
                        .to_string(),
                ));
            }
        };
        // two refusals of one file within the window: wait for the user, or ask
        let now = crate::clock::now();
        let mut st = lock(&self.st);
        let key = (session.to_string(), file.to_path_buf());
        let times = st.refusals.entry(key).or_default();
        times.retain(|t| now.duration_since(*t) < REFUSAL_WINDOW);
        times.push(now);
        if times.len() >= 2 {
            let lines = answer.as_ref().and_then(|a| a.lines);
            st.waiting.insert(
                session.to_string(),
                Waiting {
                    file: file.to_string_lossy().into_owned(),
                    lines,
                },
            );
            return Err(Refusal(format!("{text}; wait for the user or ask them")));
        }
        Err(Refusal(text))
    }
}

/// The presence feed's key for pair write ID (no ACP tool call carries it).
fn presence_call(id: WriteId) -> String {
    format!("pair:{id}")
}

/// Where a write KIND of REAL lands, as the hub knows its text: the session's served read SERVED, else the file on
/// disk (at most [`crate::work::detail::EDIT_TEXT_MAX`]); none when that text is not there or `old` is not in it once.
fn lines_of(served: Option<&Served>, real: &Path, kind: &WriteKind) -> Option<EditRange> {
    let disk;
    let text = match served {
        Some(s) => s.text.as_str(),
        None => {
            let small = std::fs::metadata(real)
                .is_ok_and(|m| m.len() <= crate::work::detail::EDIT_TEXT_MAX);
            if !small {
                return None;
            }
            disk = std::fs::read_to_string(real).ok()?;
            disk.as_str()
        }
    };
    match kind {
        WriteKind::Edit { old, new } => of_diff(text, Some(old), new, false).ok(),
        WriteKind::Whole { content } => of_diff(text, Some(text), content, true).ok(),
    }
}

/// FILE as the wire spells it.
fn abs(file: &Path) -> Result<AbsPath, Refusal> {
    AbsPath::new(file.to_string_lossy().into_owned())
        .map_err(|e| Refusal(format!("{}: {e}", file.display())))
}

/// EV into FILE's queue: the effects it raises.
fn step(st: &mut St, file: &Path, ev: Ev) -> Vec<Ev> {
    st.files.entry(file.to_path_buf()).or_default().step(ev)
}

/// The hub's task: each change that may change an answer (`coord::Signals::answers_changed`: the settings in effect, a
/// project's or a plan's matrix override, the away flag) decides every paired session's `chat.project-edit` again, so
/// a preset or a cell turned never closes its door at once ([`Door::recheck`]) instead of at its next write.
pub async fn follow_matrix(front: Arc<crate::front::Front>) {
    let mut answers = front.writer.signals.answers.subscribe();
    while answers.changed().await.is_ok() {
        for sid in front.pair.paired_sessions() {
            if let Ok(s) = front.core.agents.find(&sid) {
                s.pair_recheck().await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conn::Outbox;
    use norn::matrix::{Preset, Role, Who, effective, preset};

    fn chat(p: Preset) -> Effective {
        effective(
            &[&preset(p)],
            &Who {
                role: Some(Role::Chat),
                ..Who::default()
            },
        )
    }

    /// [D] With pair off (Balanced: the toggle is allowed, not on) the edit tools answer with the hint, before any
    /// editor is asked.
    #[tokio::test]
    async fn pair_off_tools_answer_with_the_hint() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        std::fs::write(root.join("a.txt"), "a\n").unwrap();
        let editors = Arc::new(Editors::default());
        let out = Arc::new(Outbox::new(1));
        editors.subscribe(1, out.clone());
        let door = Door::new(editors, Arc::default());
        let f = root.join("a.txt").to_string_lossy().into_owned();
        for kind in [
            WriteKind::Edit {
                old: "a".into(),
                new: "b".into(),
            },
            WriteKind::Whole {
                content: "b\n".into(),
            },
        ] {
            let r = door
                .write("s1", &root, &chat(Preset::Balanced), &f, kind)
                .await
                .unwrap_err();
            assert_eq!(r.0, PAIR_OFF);
        }
        assert!(out.take_lines().is_empty(), "no editor was asked");
        assert!(!door.paired("s1", &chat(Preset::Balanced)));
        assert!(door.paired("s1", &chat(Preset::Autonomous)));
        assert!(!door.paired("s1", &chat(Preset::Cautious)));
    }

    /// A checkout with a.txt, and a door whose editor (connection 1) is OUT.
    fn fixture() -> (tempfile::TempDir, PathBuf, Arc<Door>, Arc<Outbox>) {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        std::fs::write(root.join("a.txt"), "a\n").unwrap();
        let editors = Arc::new(Editors::default());
        let out = Arc::new(Outbox::new(1));
        editors.subscribe(1, out.clone());
        (d, root, Door::new(editors, Arc::default()), out)
    }

    fn opened(door: &Door, file: &Path, kind: super::super::open_set::FileKind) {
        door.open_ev(OpenEv::Open {
            conn: 1,
            file: file.to_path_buf(),
            kind,
        });
    }

    fn events(out: &Outbox) -> Vec<serde_json::Value> {
        out.take_lines()
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    /// [D] A file the editor has open as a large or remote buffer refuses a pair write with the reason, and the
    /// editor is sent nothing; a file no editor has goes to the disk (refused there without a read).
    #[tokio::test]
    async fn large_and_remote_refuse() {
        use super::super::open_set::{FileKind, LARGE_OR_REMOTE};
        let (_d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        for (name, kind) in [("big.log", FileKind::Large), ("far.txt", FileKind::Remote)] {
            let f = root.join(name);
            opened(&door, &f, kind);
            let edit = WriteKind::Edit {
                old: "a".into(),
                new: "b".into(),
            };
            let r = door
                .write("s1", &root, &eff, &f.to_string_lossy(), edit)
                .await
                .unwrap_err();
            assert_eq!(r.0, LARGE_OR_REMOTE, "{name}");
        }
        let r = door
            .write(
                "s1",
                &root,
                &eff,
                &root.join("a.txt").to_string_lossy(),
                WriteKind::Edit {
                    old: "a".into(),
                    new: "b".into(),
                },
            )
            .await
            .unwrap_err();
        assert_eq!(
            r.0,
            super::super::disk::UNREAD,
            "a file open nowhere goes to the disk"
        );
        assert!(events(&out).is_empty(), "nothing went to the editor");
    }

    /// [D] A write carries the step of its session it was made in to the editor, which applies it under that step.
    #[tokio::test]
    async fn a_write_carries_the_sessions_step() {
        use super::super::open_set::FileKind;
        let (_d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        let f = root.join("a.txt");
        opened(&door, &f, FileKind::Normal);
        let path = f.to_string_lossy().into_owned();
        let d2 = door.clone();
        let (r2, e2) = (root.clone(), eff.clone());
        let w = tokio::spawn(async move {
            let edit = WriteKind::Edit {
                old: "a".into(),
                new: "b".into(),
            };
            d2.write_with("s1", 7, &r2, &e2, &path, edit, None).await
        });
        // the write runs to its wait on the editor's answer without yielding: one yield lets it get there
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-apply");
        assert_eq!(sent[0]["data"]["step"], 7, "{sent:?}");
        w.abort();
    }

    /// [D] The user's own write (the Search view's) and a paired chat's never interleave on one file: the user's turn
    /// waits for the chat's write in the editor, and a chat write that comes during the turn is sent only once the turn
    /// ends.  A turn given up before it came does not hold the queue.
    #[tokio::test]
    async fn a_users_turn_and_pair_writes_take_turns() {
        use super::super::open_set::FileKind;
        let (_d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        let f = root.join("a.txt");
        opened(&door, &f, FileKind::Normal);
        let path = f.to_string_lossy().into_owned();
        let edit = || WriteKind::Edit {
            old: "a".into(),
            new: "b".into(),
        };
        let (d2, r2, e2, p2) = (door.clone(), root.clone(), eff.clone(), path.clone());
        let first = tokio::spawn(async move { d2.write("s1", &r2, &e2, &p2, edit()).await });
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent[0]["event"], "pair-apply");
        let id = sent[0]["data"]["write"].as_u64().unwrap();
        // the user's turn waits behind the write in the editor
        let d3 = door.clone();
        let f3 = f.clone();
        let turn = tokio::spawn(async move { d3.user_turn(&f3).await });
        tokio::task::yield_now().await;
        assert!(!turn.is_finished(), "the turn waits for the chat's write");
        assert!(door.answer(
            1,
            PairAnswer {
                write: id,
                result: PairResult::Applied,
                version: None,
                reason: None,
                lines: None,
                saved: None,
                not_saved: None,
            }
        ));
        let held = turn.await.unwrap();
        assert!(first.await.unwrap().is_ok());
        // a chat write during the turn waits for its end
        let (d4, r4, e4, p4) = (door.clone(), root.clone(), eff.clone(), path.clone());
        let second = tokio::spawn(async move { d4.write("s1", &r4, &e4, &p4, edit()).await });
        tokio::task::yield_now().await;
        assert!(
            events(&out).is_empty(),
            "nothing sent during the user's turn"
        );
        drop(held);
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-apply");
        second.abort();
        // a turn given up while it waited: the queue goes on without it
        let other = root.join("b.txt");
        let a = door.user_turn(&other).await;
        let d5 = door.clone();
        let o5 = other.clone();
        let gave_up = tokio::spawn(async move { d5.user_turn(&o5).await });
        tokio::task::yield_now().await;
        gave_up.abort();
        let _ = gave_up.await;
        drop(a);
        let d6 = door.clone();
        let next = tokio::spawn(async move { d6.user_turn(&other).await });
        tokio::task::yield_now().await;
        assert!(
            next.is_finished(),
            "the queue was not held by the turn given up"
        );
    }

    /// [D] The user takes the wheel while a write of the session waits in the editor: the editor is told to drop the
    /// session's writes (`pair-drop`), the write's answer is the editor's `dropped` (refused text, never applied), and
    /// every later write is refused at the door with nothing sent.  Given back, writes go to the editor again.
    #[tokio::test]
    async fn a_held_session_is_refused_at_the_door() {
        use super::super::open_set::FileKind;
        let (_d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        let f = root.join("a.txt");
        opened(&door, &f, FileKind::Normal);
        let edit = || WriteKind::Edit {
            old: "a".into(),
            new: "b".into(),
        };
        let path = f.to_string_lossy().into_owned();
        let d2 = door.clone();
        let (r2, p2, e2) = (root.clone(), path.clone(), eff.clone());
        let first = tokio::spawn(async move { d2.write("s1", &r2, &e2, &p2, edit()).await });
        // the write runs to its wait on the editor's answer without yielding: one yield lets it get there
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-apply");
        let id = sent[0]["data"]["write"].as_u64().unwrap();
        door.hold("s1", true);
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-drop");
        assert_eq!(sent[0]["data"]["session"], "s1");
        // the verdict is the editor's own answer
        assert!(door.answer(
            1,
            PairAnswer {
                write: id,
                result: PairResult::Dropped,
                version: None,
                reason: runstav::types::Text::new("held").ok(),
                lines: None,
                saved: None,
                not_saved: None,
            }
        ));
        assert_eq!(first.await.unwrap().unwrap_err().0, HELD);
        let r = door
            .write("s1", &root, &eff, &path, edit())
            .await
            .unwrap_err();
        assert_eq!(r.0, HELD);
        assert!(events(&out).is_empty(), "nothing after held");
        // given back: the next write goes to the editor
        door.hold("s1", false);
        let d3 = door.clone();
        let (r3, p3, e3) = (root.clone(), path.clone(), eff.clone());
        let _later = tokio::spawn(async move { d3.write("s1", &r3, &e3, &p3, edit()).await });
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-apply");
    }

    /// [D] The matrix makes `chat.project-edit` never (a preset or a cell changed) while a write of the paired session
    /// waits in the editor: the editor is told to drop the session's writes (`pair-drop`, reason `never`), the write's
    /// answer is the editor's `dropped`, and a later write is refused with nothing sent.  A look that changes nothing
    /// sends nothing.
    #[tokio::test]
    async fn a_never_cell_drops_the_queued_writes() {
        use super::super::open_set::FileKind;
        let (_d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        let f = root.join("a.txt");
        opened(&door, &f, FileKind::Normal);
        let edit = || WriteKind::Edit {
            old: "a".into(),
            new: "b".into(),
        };
        let path = f.to_string_lossy().into_owned();
        assert!(
            !door.recheck("s1", &eff),
            "paired and allowed: nothing to close"
        );
        let d2 = door.clone();
        let (r2, p2, e2) = (root.clone(), path.clone(), eff.clone());
        let first = tokio::spawn(async move { d2.write("s1", &r2, &e2, &p2, edit()).await });
        tokio::task::yield_now().await;
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-apply");
        let id = sent[0]["data"]["write"].as_u64().unwrap();
        let never = chat(Preset::Cautious);
        assert!(door.recheck("s1", &never));
        let sent = events(&out);
        assert_eq!(sent.len(), 1, "{sent:?}");
        assert_eq!(sent[0]["event"], "pair-drop");
        assert_eq!(sent[0]["data"]["session"], "s1");
        assert_eq!(sent[0]["data"]["reason"], "never");
        assert!(door.answer(
            1,
            PairAnswer {
                write: id,
                result: PairResult::Dropped,
                version: None,
                reason: runstav::types::Text::new("never").ok(),
                lines: None,
                saved: None,
                not_saved: None,
            }
        ));
        assert_eq!(first.await.unwrap().unwrap_err().0, NEVER_NOW);
        assert!(!door.recheck("s1", &never), "closed already");
        let r = door
            .write("s1", &root, &never, &path, edit())
            .await
            .unwrap_err();
        assert!(r.0.contains("chat.project-edit"), "{r}");
        assert!(events(&out).is_empty(), "nothing after never");
    }

    /// [C] (a real checkout in the sandbox container) A file open nowhere is written on disk through the door: a
    /// link to a file inside the checkout writes its target and stays a link; a hard link is broken on purpose (the
    /// other name keeps the old text); a link out of the checkout and a link that names nothing are refused, and
    /// nothing is written.  The record runs once, before the file changes.
    #[tokio::test]
    async fn disk_write_resolves_links_inside_the_roots_only() {
        let (d, root, door, out) = fixture();
        let eff = chat(Preset::Autonomous);
        let outside = d
            .path()
            .join("..")
            .canonicalize()
            .unwrap()
            .join(format!("pair-out-{}", std::process::id()));
        std::fs::write(&outside, "secret\n").unwrap();
        std::os::unix::fs::symlink(root.join("a.txt"), root.join("in.txt")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("out.txt")).unwrap();
        std::os::unix::fs::symlink(root.join("nothing"), root.join("dangling.txt")).unwrap();
        std::fs::hard_link(root.join("a.txt"), root.join("hard.txt")).unwrap();
        let link = root.join("in.txt").to_string_lossy().into_owned();
        door.read("s1", &root, &eff, &link).await.unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s2 = seen.clone();
        let record: super::super::disk::Record = Box::new(move |p: &Path, b: &[u8]| {
            lock(&s2).push((p.to_path_buf(), b.to_vec(), std::fs::read(p).unwrap()));
        });
        let whole = |c: &str| WriteKind::Whole { content: c.into() };
        door.write_with("s1", 0, &root, &eff, &link, whole("A\n"), Some(record))
            .await
            .unwrap();
        assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "A\n");
        assert!(
            root.join("in.txt")
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            std::fs::read_to_string(root.join("hard.txt")).unwrap(),
            "a\n",
            "the hard link is broken"
        );
        let seen = lock(&seen).clone();
        assert_eq!(
            seen,
            vec![(root.join("a.txt"), b"A\n".to_vec(), b"a\n".to_vec())]
        );
        let r = door
            .write(
                "s1",
                &root,
                &eff,
                &root.join("out.txt").to_string_lossy(),
                whole("x\n"),
            )
            .await
            .unwrap_err();
        assert!(r.0.contains("outside your project"), "{r}");
        let r = door
            .write(
                "s1",
                &root,
                &eff,
                &root.join("dangling.txt").to_string_lossy(),
                whole("x\n"),
            )
            .await
            .unwrap_err();
        assert!(r.0.contains("names nothing"), "{r}");
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "secret\n");
        assert!(!root.join("nothing").exists());
        std::fs::remove_file(&outside).unwrap();
        assert!(events(&out).is_empty(), "no editor was asked");
    }

    /// [C] (a real file in the sandbox container) A disk write keeps the file's mode, its extended attributes and its
    /// SELinux context; an attribute the file system cannot hold is reported, and the rest still checked.
    #[tokio::test]
    async fn disk_write_keeps_xattrs_and_selinux_context() {
        use std::os::unix::fs::PermissionsExt;
        let (_d, root, door, _out) = fixture();
        let eff = chat(Preset::Autonomous);
        let f = root.join("a.txt");
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o640)).unwrap();
        let user = rustix::fs::setxattr(&f, "user.drgnx", b"kept", rustix::fs::XattrFlags::empty());
        if let Err(e) = &user {
            eprintln!(
                "user attributes are not supported here ({e}): the mode and the context are checked"
            );
        }
        let context = |p: &Path| {
            let mut v = vec![0u8; 256];
            rustix::fs::getxattr(p, "security.selinux", &mut v[..])
                .ok()
                .map(|n| v[..n].to_vec())
        };
        let before = context(&f);
        let path = f.to_string_lossy().into_owned();
        door.read("s1", &root, &eff, &path).await.unwrap();
        door.write(
            "s1",
            &root,
            &eff,
            &path,
            WriteKind::Whole {
                content: "b\n".into(),
            },
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "b\n");
        assert_eq!(f.metadata().unwrap().permissions().mode() & 0o777, 0o640);
        if user.is_ok() {
            let mut v = [0u8; 16];
            let n = rustix::fs::getxattr(&f, "user.drgnx", &mut v[..]).unwrap();
            assert_eq!(&v[..n], b"kept");
        }
        assert_eq!(context(&f), before, "the SELinux context is kept");
    }
}
