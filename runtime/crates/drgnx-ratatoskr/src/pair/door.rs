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

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use norn::matrix::{Action, Effective, Verdict, decide};
use runstav::methods::agents::Waiting;
use runstav::methods::pair::{
    PairAnswer, PairApply, PairRead, PairReadAnswer, PairReconcile, PairResult,
};
use runstav::types::AbsPath;
use serde_json::json;
use tokio::sync::oneshot;

use super::writes::{Ev, FileQueue, Outcome, REREAD, Served, WriteId, plan_edit, plan_whole};
use super::{Refusal, gate, read_gate};
use crate::settings::agents::Editors;

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

/// What a write answers when no editor has the file.
pub const EDITOR_AWAY: &str = "the editor is away";

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

#[derive(Default)]
struct St {
    served: HashMap<(String, PathBuf), Served>,
    files: HashMap<PathBuf, FileQueue>,
    ordinals: HashMap<PathBuf, u64>,
    pending: HashMap<WriteId, Pending>,
    /// Reads waiting for an editor's text: the connection asked, and where its answer goes.
    reads: HashMap<u64, (u64, oneshot::Sender<PairReadAnswer>)>,
    refusals: HashMap<(String, PathBuf), Vec<tokio::time::Instant>>,
    waiting: HashMap<String, Waiting>,
}

/// The hub's door for paired chats: one per hub.
pub struct Door {
    editors: Arc<Editors>,
    st: Mutex<St>,
    next: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Door {
    pub fn new(editors: Arc<Editors>) -> Arc<Door> {
        Arc::new(Door {
            editors,
            st: Mutex::default(),
            next: AtomicU64::new(1),
        })
    }

    fn id(&self) -> u64 {
        self.next.fetch_add(1, Ordering::Relaxed)
    }

    /// Whether a session with the cells EFF is paired now.
    pub fn paired(&self, _session: &str, eff: &Effective) -> bool {
        decide(eff, Action::ChatProjectEdit, None) == Verdict::Allow
    }

    /// SESSION's `waiting {file, lines}`: two refusals of one file, until a write of it applies.
    pub fn waiting(&self, session: &str) -> Option<Waiting> {
        lock(&self.st).waiting.get(session).cloned()
    }

    /// The editor connection a write or read of FILE goes to.
    fn editor_for(&self, _file: &Path) -> Option<u64> {
        self.editors.first()
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
        let from_editor = match self.editor_for(&real) {
            Some(conn) => self.ask_editor(conn, &real).await?,
            None => None,
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
        if !self.paired(session, eff) {
            // the gate's own refusal (a never cell, a protected path) says more than "off"
            gate(eff, root, Path::new(path))?;
            return Err(Refusal(PAIR_OFF.into()));
        }
        let real = gate(eff, root, Path::new(path))?;
        let conn = self
            .editor_for(&real)
            .ok_or_else(|| Refusal(EDITOR_AWAY.into()))?;
        let rx = {
            let mut st = lock(&self.st);
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
            let fx = st.files.entry(real.clone()).or_default().step(Ev::Submit {
                id,
                session: session.to_string(),
            });
            self.run(&mut st, &real, fx);
            rx
        };
        let (outcome, answer) = rx.await.unwrap_or((Outcome::Lost, None));
        self.verdict(session, &real, outcome, answer)
    }

    /// The effects FX of FILE's queue, done under the door's lock (sends only queue a line; a timer is a task).
    fn run(self: &Arc<Self>, st: &mut St, file: &Path, fx: Vec<Ev>) {
        let mut work: Vec<Ev> = fx.into_iter().rev().collect();
        while let Some(ev) = work.pop() {
            let more = match ev {
                Ev::Send { id } => {
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

    /// Editor connection CONN is gone: its writes in flight are unknown, the reads waiting for it give up.
    pub fn editor_gone(self: &Arc<Self>, conn: u64) {
        let mut st = lock(&self.st);
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
            Outcome::Refused(reason) => {
                let lines = answer.as_ref().and_then(|a| a.lines);
                refused_text(&reason, lines)
            }
            Outcome::Dropped => answer.as_ref().and_then(|a| a.reason.as_ref()).map_or_else(
                || {
                    "the editor did not get to it in time; nothing of it was applied: try again"
                        .to_string()
                },
                |r| {
                    format!(
                        "{}; nothing of it was applied",
                        refused_text(r.as_str(), None)
                    )
                },
            ),
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

/// FILE as the wire spells it.
fn abs(file: &Path) -> Result<AbsPath, Refusal> {
    AbsPath::new(file.to_string_lossy().into_owned())
        .map_err(|e| Refusal(format!("{}: {e}", file.display())))
}

/// EV into FILE's queue: the effects it raises.
fn step(st: &mut St, file: &Path, ev: Ev) -> Vec<Ev> {
    st.files.entry(file.to_path_buf()).or_default().step(ev)
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
        let door = Door::new(editors);
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
}
