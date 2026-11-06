//! A paired chat's writes as data, and the order of one file's writes (a pure core, [`FileQueue`]).
//!
//! - **What a write becomes** ([`plan_edit`], [`plan_whole`]): `edit_file {old, new}` travels as it is (Emacs finds
//!   the one match at apply time); `write_file {content}` of an existing file needs the read the hub served to that
//!   session, and is diffed into line hunks against it, carrying its version ([`hunks`]); a new file needs no read.
//! - **One file's order** ([`FileQueue`]): writes go to the editor one at a time, in the order they came; the next is
//!   sent when the editor answered the one before.  The verdict is only ever the editor's answer: the hub's own timer
//!   (`Expired`) never refuses, it starts a reconcile, which the editor answers from what it applied.  So an applied
//!   write is never reported refused, and a write refused here (the door closed before it was sent) is never sent.

use std::collections::VecDeque;

pub use runstav::methods::pair::Edit;

use super::Refusal;

/// The refusal that sends the agent back to read the editor's text.
pub const REREAD: &str =
    "read it with read_file (the editor's text, unsaved edits included), then retry";

/// A read the hub served to a session: the text and the editor's version of it (none: read from disk).
#[derive(Clone, Debug, PartialEq)]
pub struct Served {
    pub text: String,
    pub version: Option<u64>,
}

/// A write ready for the editor: its edits and the version they are based on (none: no base, `edit_file`'s).
#[derive(Clone, Debug, PartialEq)]
pub struct Planned {
    pub edits: Vec<Edit>,
    pub version: Option<u64>,
}

/// `edit_file {old, new}`: no base; an empty `old` is refused (it would match everywhere).
pub fn plan_edit(old: &str, new: &str) -> Result<Planned, Refusal> {
    if old.is_empty() {
        return Err(Refusal(format!(
            "old is empty: give the exact text to replace; {REREAD}"
        )));
    }
    Ok(Planned {
        edits: vec![Edit::Replace {
            old: old.to_string(),
            new: new.to_string(),
        }],
        version: None,
    })
}

/// `write_file {content}`: an EXISTS file needs SERVED, the read the hub served to this session (clean buffer or
/// dirty), and becomes the line hunks from it to CONTENT at its version; a new file is one hunk with no base.
pub fn plan_whole(
    served: Option<&Served>,
    exists: bool,
    content: &str,
) -> Result<Planned, Refusal> {
    if !exists {
        return Ok(Planned {
            edits: vec![Edit::Lines {
                line: 1,
                delete: 0,
                text: content.to_string(),
            }],
            version: None,
        });
    }
    let Some(read) = served else {
        return Err(Refusal(format!(
            "this file exists and you have not read it through drgnx: {REREAD}"
        )));
    };
    Ok(Planned {
        edits: hunks(&read.text, content),
        version: read.version,
    })
}

/// The line hunks that turn OLD into NEW (Myers, `similar`), each a run of changed lines of OLD; adjacent changes are
/// one hunk.
pub fn hunks(old: &str, new: &str) -> Vec<Edit> {
    use similar::{DiffOp, TextDiff};
    let diff = TextDiff::configure()
        .algorithm(similar::Algorithm::Myers)
        .diff_lines(old, new);
    let new_lines: Vec<&str> = diff.new_slices().to_vec();
    let mut out: Vec<(usize, usize, usize, usize)> = Vec::new();
    for op in diff.ops() {
        let (o, ol, n, nl) = match *op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete {
                old_index,
                old_len,
                new_index,
            } => (old_index, old_len, new_index, 0),
            DiffOp::Insert {
                old_index,
                new_index,
                new_len,
            } => (old_index, 0, new_index, new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => (old_index, old_len, new_index, new_len),
        };
        match out.last_mut() {
            Some(last) if last.0 + last.1 == o && last.2 + last.3 == n => {
                last.1 += ol;
                last.3 += nl;
            }
            _ => out.push((o, ol, n, nl)),
        }
    }
    out.into_iter()
        .map(|(o, ol, n, nl)| Edit::Lines {
            line: o as u64 + 1,
            delete: ol as u64,
            text: new_lines[n..n + nl].concat(),
        })
        .collect()
}

/// How the editor ended a write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Applied,
    /// Refused whole, and why (the editor's reason).
    Refused(String),
    /// Dropped unapplied: its time in the editor's queue ran out, or the door closed while it waited there.
    Dropped,
    /// The editor went away before it answered: whether the write landed is unknown (never reported refused).
    Lost,
}

pub type WriteId = u64;

/// One file's writes, as the core sees them.  `Submit`, `Answer`, `Expired` and `Close` come in; `Send`, `Reconcile`
/// and `Verdict` are what the core asks the shell to do (and re-enter, so a test sees them).
#[derive(Clone, Debug, PartialEq)]
pub enum Ev {
    /// A write for this file, from SESSION.
    Submit { id: WriteId, session: String },
    /// The editor's `pair/answer` for write ID (to its `pair-apply` or its `pair-reconcile`).
    Answer { id: WriteId, outcome: Outcome },
    /// The hub's timer: write ID's time to live and the margin have passed with no answer.
    Expired { id: WriteId },
    /// The door closed for SESSION (pair off, the wheel taken): its writes not yet sent are refused with WHY.
    Close { session: String, why: String },
    /// Send write ID to the editor (`pair-apply`).
    Send { id: WriteId },
    /// Ask the editor what became of write ID (`pair-reconcile`).
    Reconcile { id: WriteId },
    /// Write ID's verdict, to the agent.
    Verdict { id: WriteId, outcome: Outcome },
}

#[cfg(test)]
skuld::events!(Ev {
    Submit,
    Answer,
    Expired,
    Close,
    Send,
    Reconcile,
    Verdict
});

#[cfg(test)]
impl skuld::Core for FileQueue {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        FileQueue::step(self, ev)
    }
}

/// The order of one file's writes.
#[derive(Debug, Default)]
pub struct FileQueue {
    waiting: VecDeque<(WriteId, String)>,
    /// The write the editor has, and whether a reconcile was asked for.
    in_flight: Option<(WriteId, bool)>,
    /// Every verdict given, in order (a test reads it; the shell keeps none).
    pub verdicts: Vec<(WriteId, Outcome)>,
    /// Every write sent, in order.
    pub sent: Vec<WriteId>,
}

impl FileQueue {
    /// The write the editor has now.
    pub fn in_flight(&self) -> Option<WriteId> {
        self.in_flight.map(|(id, _)| id)
    }

    /// Whether nothing waits and nothing is in flight.
    pub fn idle(&self) -> bool {
        self.in_flight.is_none() && self.waiting.is_empty()
    }

    fn next(&mut self, out: &mut Vec<Ev>) {
        if self.in_flight.is_none()
            && let Some((id, _)) = self.waiting.pop_front()
        {
            self.in_flight = Some((id, false));
            out.push(Ev::Send { id });
        }
    }

    /// One event; the effects it raises.
    pub fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let mut out = Vec::new();
        match ev {
            Ev::Submit { id, session } => {
                self.waiting.push_back((id, session));
                self.next(&mut out);
            }
            Ev::Answer { id, outcome } => {
                // only the write in flight has an answer; a second answer to one already given changes nothing
                if self.in_flight() == Some(id) {
                    self.in_flight = None;
                    out.push(Ev::Verdict { id, outcome });
                    self.next(&mut out);
                }
            }
            Ev::Expired { id } => {
                if let Some((f, asked)) = self.in_flight.as_mut()
                    && *f == id
                    && !*asked
                {
                    *asked = true;
                    out.push(Ev::Reconcile { id });
                }
            }
            Ev::Close { session, why } => {
                let (gone, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.waiting)
                    .into_iter()
                    .partition(|(_, s)| *s == session);
                self.waiting = kept.into();
                for (id, _) in gone {
                    out.push(Ev::Verdict {
                        id,
                        outcome: Outcome::Refused(why.clone()),
                    });
                }
            }
            Ev::Send { id } => self.sent.push(id),
            Ev::Verdict { id, outcome } => self.verdicts.push((id, outcome)),
            Ev::Reconcile { .. } => {}
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skuld::{Bound, Partial, every_order};

    fn submit(id: WriteId, s: &str) -> Ev {
        Ev::Submit {
            id,
            session: s.into(),
        }
    }

    fn answer(id: WriteId, o: Outcome) -> Ev {
        Ev::Answer { id, outcome: o }
    }

    /// [A] Three writes to one file from two chats, the editor answering each as it gets it (applied, refused,
    /// applied), with a reconcile timer on the first: in every order the editor gets them one at a time in the order
    /// they came, and each verdict is the editor's own.  Edges: the editor answers write N only after the hub
    /// submitted it (the shell sends it no sooner), and a timer fires only for a write submitted.
    #[test]
    fn every_order_writes_to_one_file_apply_in_order() {
        let mut p = Partial::new();
        let hub = p.source("hub", vec![submit(1, "a"), submit(2, "b"), submit(3, "a")]);
        let ed = p.source(
            "editor",
            vec![
                answer(1, Outcome::Applied),
                answer(2, Outcome::Refused("the user is editing lines 3-4".into())),
                answer(3, Outcome::Applied),
            ],
        );
        let clock = p.source("clock", vec![Ev::Expired { id: 1 }]);
        // a third chat's door closes: none of these writes is its own
        p.source(
            "user",
            vec![Ev::Close {
                session: "c".into(),
                why: "pair mode was turned off by the user".into(),
            }],
        );
        for i in 0..3 {
            p.before((hub, i), (ed, i));
        }
        p.before((hub, 0), (clock, 0));
        let r = every_order(&p, Bound::default(), FileQueue::default, |q, _| {
            if q.sent != [1, 2, 3] {
                return Err(format!("sent {:?}", q.sent));
            }
            let want = vec![
                (1, Outcome::Applied),
                (2, Outcome::Refused("the user is editing lines 3-4".into())),
                (3, Outcome::Applied),
            ];
            if q.verdicts != want {
                return Err(format!("verdicts {:?}", q.verdicts));
            }
            q.idle().then_some(()).ok_or("not idle".into())
        });
        assert!(r.orders > 1, "{r:?}");
        assert!(r.kinds_seen.contains("Reconcile"), "{r:?}");
    }

    /// [A] The editor started an apply just before its deadline: its `applied` answer arrives after the hub's timer
    /// fired.  The timer only asks for a reconcile; the editor's answer (to the apply or to the reconcile, whichever
    /// comes first) is the verdict, so the write is reported applied in every order, once, and a later write is sent
    /// only after it.  A write the door closed before it was sent is refused and never sent.
    #[test]
    fn every_order_a_late_applied_answer_is_still_applied() {
        let mut p = Partial::new();
        let hub = p.source("hub", vec![submit(1, "a"), submit(2, "a")]);
        let clock = p.source("clock", vec![Ev::Expired { id: 1 }]);
        let ed = p.source(
            "editor",
            vec![answer(1, Outcome::Applied), answer(1, Outcome::Applied)],
        );
        let user = p.source(
            "user",
            vec![Ev::Close {
                session: "a".into(),
                why: "pair mode was turned off by the user".into(),
            }],
        );
        p.before((hub, 0), (clock, 0));
        p.before((hub, 0), (ed, 0));
        p.before((hub, 1), (user, 0));
        every_order(&p, Bound::default(), FileQueue::default, |q, order| {
            let one = q.verdicts.iter().find(|(id, _)| *id == 1).cloned();
            if one != Some((1, Outcome::Applied)) {
                return Err(format!("write 1: {one:?}"));
            }
            if q.verdicts.iter().filter(|(id, _)| *id == 1).count() != 1 {
                return Err(format!("write 1 twice: {:?}", q.verdicts));
            }
            // write 2 was sent only if the editor's answer to 1 came before the door closed; else refused, unsent
            let closed_first = order.iter().position(|e| matches!(e, Ev::Close { .. }))
                < order.iter().position(|e| matches!(e, Ev::Answer { .. }));
            let two = q.verdicts.iter().find(|(id, _)| *id == 2).cloned();
            match (closed_first, two, q.sent.contains(&2)) {
                (true, Some((2, Outcome::Refused(_))), false) => Ok(()),
                (false, None, true) => Ok(()),
                (c, t, s) => Err(format!("closed first {c}, write 2 {t:?}, sent {s}")),
            }
        });
    }

    /// [D] A whole-file write of an existing file is diffed against the read the hub served, at its version: only the
    /// changed lines travel.
    #[test]
    fn whole_write_diffs_against_the_read_served() {
        let read = Served {
            text: "a\nb\nc\nd\ne\n".into(),
            version: Some(7),
        };
        let p = plan_whole(Some(&read), true, "a\nB\nc\nd\ne\nf\n").unwrap();
        assert_eq!(p.version, Some(7));
        assert_eq!(
            p.edits,
            vec![
                Edit::Lines {
                    line: 2,
                    delete: 1,
                    text: "B\n".into()
                },
                Edit::Lines {
                    line: 6,
                    delete: 0,
                    text: "f\n".into()
                },
            ]
        );
        // adjacent changes are one hunk; a deletion carries no text
        assert_eq!(
            hunks("1\n2\n3\n4\n", "1\nx\ny\n4\n"),
            vec![Edit::Lines {
                line: 2,
                delete: 2,
                text: "x\ny\n".into()
            }]
        );
        assert_eq!(
            hunks("1\n2\n3\n", "1\n3\n"),
            vec![Edit::Lines {
                line: 2,
                delete: 1,
                text: String::new()
            }]
        );
        assert!(hunks("same\n", "same\n").is_empty());
    }

    /// [D] An existing file with no read the hub served is refused, whether the buffer is clean or dirty (the door
    /// never diffs against the disk: a native read before a save would revert the save).
    #[test]
    fn whole_write_without_a_served_read_is_refused_even_when_clean() {
        let r = plan_whole(None, true, "new text\n").unwrap_err();
        assert!(r.0.contains("read_file"), "{r}");
    }

    /// [D] A file that does not exist needs no read: one hunk, no base.
    #[test]
    fn a_new_file_needs_no_read() {
        let p = plan_whole(None, false, "fresh\n").unwrap();
        assert_eq!(p.version, None);
        assert_eq!(
            p.edits,
            vec![Edit::Lines {
                line: 1,
                delete: 0,
                text: "fresh\n".into()
            }]
        );
    }

    /// [D] Every refusal that asks for a re-read names `read_file`, so a chat does not re-read the disk and loop.
    #[test]
    fn refusals_that_ask_for_a_reread_name_read_file() {
        assert!(REREAD.contains("read_file"));
        assert!(plan_edit("", "x").unwrap_err().0.contains("read_file"));
        assert!(
            plan_whole(None, true, "x")
                .unwrap_err()
                .0
                .contains("read_file")
        );
        for reason in ["no-match", "several", "gap"] {
            assert!(
                super::super::door::refused_text(reason, None).contains("read_file"),
                "{reason}"
            );
        }
        assert_eq!(
            plan_edit("a", "b").unwrap().edits,
            vec![Edit::Replace {
                old: "a".into(),
                new: "b".into()
            }]
        );
    }
}
