//! The panel's row cache in every order of transcript changes, step facts and envs: an editor replays every patch and
//! must end holding, for each class, exactly the rows a whole build of the transcript gives.

use super::{Panels, Source, view_of};
use crate::agents::session::rows::{self, Facts, GroupIn};
use crate::view::{Key, Store, is_reset};
use drgnx_rows::fit::FontSet;
use drgnx_rows::{Op, Patch, Row};
use runstav::methods::agents::{Entry, EntryType};
use runstav::methods::view::{Display, ViewEnv};
use serde_json::{Map, Value, json};
use skuld::{Bound, Core, Partial, every_order};
use std::collections::{BTreeMap, BTreeSet};

const CONN: u64 = 1;
const SID: &str = "s1";

fn key(class: &str) -> Key {
    (CONN, view_of(SID), class.into())
}

fn env(class: &str, epoch: u64, width: u32) -> ViewEnv {
    ViewEnv {
        view: view_of(SID),
        class: class.into(),
        epoch,
        display: if class == "tty" {
            Display::Tty
        } else {
            Display::Gui
        },
        scale: 1.0,
        fonts: vec![],
        cell: (8, 16),
        width_px: width,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
        attach: false,
    }
}

fn entry(kind: EntryType, rest: Value) -> Entry {
    let rest: Map<String, Value> = rest.as_object().cloned().unwrap_or_default();
    Entry { kind, rest }
}

/// What the transcript and the editors are fed.
#[derive(Clone, Debug)]
enum Act {
    /// A tool call starts (its step's seq is its index).
    Tool,
    /// A thought arrives.
    Thought,
    /// The agent says something.
    Say,
    /// Entry N (when there is one) changes: a tool completes with output (a failed one opens it), any other entry's
    /// text grows.
    Change(usize),
    /// The step of entry N closes: its facts arrive.
    Step(usize),
    /// The editor's env for CLASS at EPOCH (WIDTH px).
    Env(&'static str, u64, u32),
}

/// The session's transcript, the hub's panels and store, and the patches sent per class.
struct World {
    entries: Vec<Entry>,
    panels: Panels,
    store: Store,
    out: Vec<Patch>,
}

/// The groups of ENTRIES from FROM on, ONLY those holding one of its indexes when given, as the session hands them.
fn groups_of(entries: &[Entry], from: usize, only: Option<&BTreeSet<usize>>) -> Vec<GroupIn> {
    let tail: Vec<(usize, &Entry)> = entries.iter().enumerate().skip(from).collect();
    rows::groups(&tail)
        .into_iter()
        .filter(|(h, t)| only.is_none_or(|o| o.contains(h) || t.iter().any(|i| o.contains(i))))
        .map(|(head, thoughts)| GroupIn {
            head,
            entry: entries[head].clone(),
            thoughts: thoughts.iter().map(|t| entries[*t].clone()).collect(),
            blocks: None,
        })
        .collect()
}

fn build(
    panels: &Panels,
    entries: &[Entry],
    class: &str,
    e: &ViewEnv,
    dirty: Option<&BTreeSet<usize>>,
) -> Vec<Row> {
    let groups = |from: usize, only: Option<&BTreeSet<usize>>| groups_of(entries, from, only);
    let src = Source {
        sid: SID,
        n: entries.len(),
        groups: &groups,
        always: &|_: &Entry| false,
    };
    panels.rows_of(&src, &key(class), e, &FontSet::new(), dirty)
}

impl World {
    fn new() -> Self {
        let panels = Panels::default();
        super::lock(&panels.facts).insert(SID.into(), (0, BTreeMap::new()));
        World {
            entries: vec![],
            panels,
            store: Store::new(100),
            out: vec![],
        }
    }

    /// Every class with an env gets the rows DIRTY changes (none: all of them).
    fn publish(&mut self, dirty: Option<&BTreeSet<usize>>) {
        for class in ["gui", "tty"] {
            let Some(e) = self.store.env_of(&key(class)).cloned() else {
                continue;
            };
            let rows = build(&self.panels, &self.entries, class, &e, dirty);
            if let Some(p) = self.store.publish(&key(class), rows, &[]) {
                self.out.push(p);
            }
        }
    }

    fn act(&mut self, a: Act) {
        let n = self.entries.len();
        let dirty = |i: usize| Some(BTreeSet::from([i]));
        match a {
            Act::Tool => {
                self.entries.push(entry(
                    EntryType::Tool,
                    json!({"title": format!("Read f{n}"), "kind": "read", "status": "pending", "step": n}),
                ));
                self.publish(dirty(n).as_ref());
            }
            Act::Thought => {
                self.entries
                    .push(entry(EntryType::Thought, json!({"text": "hmm"})));
                self.publish(dirty(n).as_ref());
            }
            Act::Say => {
                self.entries
                    .push(entry(EntryType::Agent, json!({"text": "Hello"})));
                self.publish(dirty(n).as_ref());
            }
            Act::Change(i) => {
                let Some(e) = self.entries.get_mut(i) else {
                    return;
                };
                if e.kind == EntryType::Tool {
                    let done = e.rest.get("status") == Some(&json!("completed"));
                    e.rest.insert(
                        "status".into(),
                        json!(if done { "failed" } else { "completed" }),
                    );
                    e.rest.insert("content".into(), json!("line one\nline two"));
                } else {
                    let t = e
                        .rest
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    e.rest.insert("text".into(), json!(format!("{t} more")));
                }
                self.publish(dirty(i).as_ref());
            }
            Act::Step(i) => {
                {
                    let mut f = super::lock(&self.panels.facts);
                    let (v, map) = f.get_mut(SID).expect("shown");
                    map.insert(
                        i as u64,
                        Facts {
                            start: Some(1.0),
                            end: Some(3.5),
                            cost: Some(0.01),
                            revertible: true,
                            ..Facts::default()
                        },
                    );
                    *v += 1;
                }
                self.publish(None);
            }
            Act::Env(class, epoch, width) => {
                self.store.env(CONN, env(class, epoch, width));
                self.publish(None);
            }
        }
    }
}

fn apply(rows: &mut Vec<Row>, ops: &[Op]) -> Result<(), String> {
    for op in ops {
        match op {
            Op::Reset(r) => *rows = r.clone(),
            Op::Insert { after, rows: new } => {
                let at = match after {
                    None => 0,
                    Some(k) => {
                        rows.iter()
                            .position(|r| &r.key == k)
                            .ok_or(format!("insert after unknown {k}"))?
                            + 1
                    }
                };
                rows.splice(at..at, new.iter().cloned());
            }
            Op::Replace(new) => {
                for n in new {
                    let i = rows
                        .iter()
                        .position(|r| r.key == n.key)
                        .ok_or(format!("replace of unknown {}", n.key))?;
                    rows[i] = n.clone();
                }
            }
            Op::Remove(keys) => {
                for k in keys {
                    let i = rows
                        .iter()
                        .position(|r| &r.key == k)
                        .ok_or(format!("remove of unknown {k}"))?;
                    rows.remove(i);
                }
            }
        }
    }
    Ok(())
}

/// Replays the patches per class (each on the version it names) and compares with a whole build by fresh panels.
fn check(w: &World) -> Result<(), String> {
    let mut held: BTreeMap<String, (u64, Vec<Row>)> = BTreeMap::new();
    for p in &w.out {
        let h = held.entry(p.class.clone()).or_default();
        if !is_reset(p) && h.0 != p.base {
            return Err(format!(
                "{} patch on base {} at version {}",
                p.class, p.base, h.0
            ));
        }
        apply(&mut h.1, &p.ops)?;
        h.0 = p.version;
    }
    let fresh = Panels::default();
    *super::lock(&fresh.facts) = super::lock(&w.panels.facts).clone();
    for class in ["gui", "tty"] {
        let Some(e) = w.store.env_of(&key(class)) else {
            continue;
        };
        let want = build(&fresh, &w.entries, class, e, None);
        let have = held.get(class).map(|h| h.1.clone()).unwrap_or_default();
        if have != want {
            return Err(format!("{class} holds {have:#?}\nnot {want:#?}"));
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
enum Ev {
    Transcript(Act),
    Editor(Act),
    Steps(Act),
}
skuld::events!(Ev {
    Transcript,
    Editor,
    Steps
});

impl Core for World {
    type Event = Ev;
    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        match ev {
            Ev::Transcript(a) | Ev::Editor(a) | Ev::Steps(a) => self.act(a),
        }
        vec![]
    }
}

#[test]
fn every_order_entry_patches_converge() {
    let mut p = Partial::new();
    p.source(
        "transcript",
        vec![
            Ev::Transcript(Act::Say),
            Ev::Transcript(Act::Tool),
            Ev::Transcript(Act::Thought),
            Ev::Transcript(Act::Change(1)),
            Ev::Transcript(Act::Thought),
            Ev::Transcript(Act::Change(0)),
            Ev::Transcript(Act::Change(1)),
        ],
    );
    p.source(
        "editors",
        vec![
            Ev::Editor(Act::Env("gui", 1, 400)),
            Ev::Editor(Act::Env("tty", 1, 640)),
            Ev::Editor(Act::Env("gui", 2, 300)),
        ],
    );
    p.source("steps", vec![Ev::Steps(Act::Step(1))]);
    every_order(&p, Bound::default(), World::new, |w, _| check(w));
}

#[test]
fn two_classes_get_two_versions() {
    let mut w = World::new();
    w.act(Act::Env("gui", 1, 400));
    w.act(Act::Say);
    w.act(Act::Tool);
    w.act(Act::Env("tty", 1, 640));
    w.act(Act::Change(1));
    let of = |class: &str| -> Vec<(u64, u64)> {
        w.out
            .iter()
            .filter(|p| p.class == class)
            .map(|p| (p.base, p.version))
            .collect()
    };
    let (gui, tty) = (of("gui"), of("tty"));
    // each class's patches chain on its own versions: the tty's first is a reset however far the gui's went
    for v in [&gui, &tty] {
        for pair in v.windows(2) {
            assert_eq!(
                pair[1].0, pair[0].1,
                "a patch names the version before it: {v:?}"
            );
        }
    }
    assert_eq!(gui.len(), 4, "{gui:?}");
    assert_eq!(tty.len(), 2, "{tty:?}");
    let first_tty = w
        .out
        .iter()
        .find(|p| p.class == "tty")
        .expect("a tty patch");
    assert!(is_reset(first_tty));
    assert!(
        tty[0].1 < gui[3].1,
        "the tty's versions are its own: {tty:?} {gui:?}"
    );
    // the tool's right-aligned facts would differ per class; here its rows differ by nothing but the class's env
    let last = |class: &str| {
        w.out
            .iter()
            .rev()
            .find(|p| p.class == class)
            .expect("a patch")
            .clone()
    };
    assert!(
        matches!(last("tty").ops.as_slice(), [Op::Replace(r)] if r.iter().all(|r| r.key.starts_with("e:1")))
    );
}

#[test]
fn the_model_holds_the_steps_and_a_new_one_changes_only_its_own() {
    // pattern D (pure)
    let diff = json!({"content": [{"type": "diff", "path": "a", "oldText": "x", "newText": "y"}]});
    let paired = json!({"rawInput": {"path": "b", "old": "x", "new": "y"}});
    let entries = [
        entry(EntryType::User, json!({"text": "one"})),
        entry(EntryType::Tool, diff),
        entry(EntryType::Thought, json!({"text": "hm"})),
        entry(EntryType::Agent, json!({"text": "ok"})),
        entry(EntryType::Plan, json!({})),
        entry(EntryType::Tool, json!({"title": "ls"})),
        entry(EntryType::User, json!({"text": "two"})),
        entry(EntryType::Tool, paired),
    ];
    let tail: Vec<(usize, &Entry)> = entries.iter().enumerate().collect();
    // the thought folds under its tool call, the plan draws no row
    let d = super::panel_doc(&super::heads_of(&tail));
    assert_eq!(d.descriptor["scheme"], "list");
    let ids = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        d.nodes.keys().cloned().collect::<Vec<_>>(),
        ids(&["e:0", "e:1", "e:3", "e:5", "e:6", "e:7"])
    );
    assert!(
        d.lists.is_empty(),
        "no list: Sjá sends one whole each time it changes"
    );
    assert_eq!(d.nodes["e:5"]["kind"], "tool");
    assert_eq!(d.nodes["e:6"]["kind"], "user");
    let diff_of = |id: &str| d.nodes[id]["fields"][1].clone();
    assert_eq!(diff_of("e:1"), json!(["diff", 1]));
    assert_eq!(diff_of("e:5"), json!(["diff", 0]));
    assert_eq!(diff_of("e:7"), json!(["diff", 1]), "a paired chat's edit");
    // a new step adds its node; nothing else changes
    for extra in [3, 5] {
        let more: Vec<(usize, &Entry)> = entries
            .iter()
            .chain([&entries[extra]])
            .enumerate()
            .collect();
        let ops = super::panel_doc(&super::heads_of(&more)).diff(&d);
        assert_eq!(ops.len(), 1, "{ops:?}");
        assert_eq!(
            ops[0]["nodes"].as_array().map(|n| n[0]["id"].clone()),
            Some(json!("e:8"))
        );
        assert_eq!(ops[0]["nodes"].as_array().map(Vec::len), Some(1));
    }
}

#[test]
fn rows_name_the_step_they_draw() {
    // pattern D (pure: the store and the builder, no clock)
    let mut w = World::new();
    w.act(Act::Env("gui", 1, 400));
    w.act(Act::Tool);
    w.act(Act::Thought);
    w.act(Act::Say);
    let rows = build(&w.panels, &w.entries, "gui", &env("gui", 1, 400), None);
    for r in &rows {
        let head = if r.key.starts_with("e:1") || r.key.starts_with("e:0") {
            "e:0"
        } else {
            "e:2"
        };
        assert!(
            r.props
                .iter()
                .any(|p| p.2 == "drgnx-work-id" && p.3 == json!(head)),
            "{} names {head}: {:?}",
            r.key,
            r.props
        );
    }
}

#[test]
fn the_model_is_made_again_only_when_a_step_can_change() {
    // pattern D (pure)
    let p = Panels::default();
    assert_eq!(p.model_due(1, "v", 3, false, None), Some(0), "the first");
    assert_eq!(
        p.model_due(1, "v", 3, false, None),
        None,
        "a streamed chunk of a message"
    );
    assert_eq!(p.model_due(1, "v", 3, true, None), Some(0), "a full build");
    assert_eq!(p.model_due(1, "v", 4, false, None), Some(0), "a new entry");
    assert_eq!(
        p.model_due(2, "v", 4, false, None),
        Some(0),
        "another connection"
    );
}

#[test]
fn an_appended_step_extends_the_model() {
    // pattern D (pure): the steps from the last one on are made again, not the whole transcript
    use super::Made;
    use EntryType::{Agent, Tool, User};
    let p = Panels::default();
    let three = vec![(0, User, false), (1, Tool, false), (2, Agent, false)];
    assert_eq!(p.model_due(1, "v", 3, false, None), Some(0));
    assert_eq!(p.model_made(1, "v", 0, three.clone()), Made::Whole(three));
    assert_eq!(
        p.model_due(1, "v", 5, false, None),
        Some(2),
        "new entries: from the last step"
    );
    assert_eq!(
        p.model_made(1, "v", 2, vec![(2, Agent, false), (4, User, false)]),
        Made::Steps(vec![(4, User, false)]),
        "the last step is unchanged"
    );
    assert_eq!(
        p.model_due(1, "v", 5, false, Some(1)),
        Some(1),
        "a tool call changed: from it"
    );
    assert_eq!(
        p.model_made(
            1,
            "v",
            1,
            vec![(1, Tool, true), (2, Agent, false), (4, User, false)]
        ),
        Made::Steps(vec![(1, Tool, true)])
    );
    assert_eq!(
        p.model_due(1, "v", 6, false, None),
        Some(4),
        "from the last step"
    );
    let all = vec![
        (0, User, false),
        (1, Tool, true),
        (2, Agent, false),
        (5, Agent, false),
    ];
    assert_eq!(
        p.model_made(1, "v", 4, vec![(5, Agent, false)]),
        Made::Whole(all),
        "a step went: the whole"
    );
    assert_eq!(
        p.model_due(1, "v", 6, true, None),
        Some(0),
        "a full build: the whole"
    );
}
