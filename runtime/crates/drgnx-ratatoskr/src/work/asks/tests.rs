//! The current ask: in every order of its sources (pattern A), and its rules alone (pattern D).

use super::*;
use skuld::{Bound, Partial, every_order};

skuld::events!(AskEv {
    UserMessage,
    SteerDelivered,
    GraphWrite,
    AgentStart,
    SessionGone,
    Restoring,
    Restore,
    NoRestore
});

fn said(session: &str, text: &str, channel: &str) -> AskEv {
    AskEv::UserMessage {
        session: session.into(),
        text: text.into(),
        channel: channel.into(),
        message_id: None,
        at: 1.0,
    }
}

fn steer(session: &str, text: &str) -> AskEv {
    AskEv::SteerDelivered {
        session: session.into(),
        text: text.into(),
        at: 2.0,
    }
}

fn wrote(session: &str, entity: &str) -> AskEv {
    AskEv::GraphWrite {
        session: session.into(),
        entity: entity.into(),
        kind: entity.split(':').next().unwrap().into(),
    }
}

fn started(starter: Option<&str>, new: &str) -> AskEv {
    AskEv::AgentStart {
        starter: starter.map(str::to_string),
        new: new.into(),
    }
}

fn gone(session: &str) -> AskEv {
    AskEv::SessionGone {
        session: session.into(),
    }
}

/// The core under test and what it said to write, in order; nothing re-enters.
#[derive(Default)]
struct Harness {
    core: AskCore,
    outs: Vec<AskOut>,
}

impl skuld::Core for Harness {
    type Event = AskEv;
    fn step(&mut self, ev: AskEv) -> Vec<AskEv> {
        let out = self.core.step(ev);
        self.outs.extend(out);
        Vec::new()
    }
}

/// OUTS as the links they make, `(the ask's session, its text, the entity)`, after checking that each ask is made
/// once, before its first link, and that no link is written twice.
fn links_of(outs: &[AskOut]) -> Result<BTreeSet<(String, String, String)>, String> {
    let mut made: BTreeMap<u64, (String, String)> = BTreeMap::new();
    let mut links = BTreeSet::new();
    for o in outs {
        match o {
            AskOut::Create {
                key, text, session, ..
            } => {
                if made.insert(*key, (session.clone(), text.clone())).is_some() {
                    return Err(format!("ask {key} made twice"));
                }
            }
            AskOut::Adopt { key, id } => {
                // an ask an earlier hub made: known by its entity id from here on
                made.insert(*key, ("adopted".into(), id.clone()));
            }
            AskOut::Link { ask_key, to } => {
                let Some((s, t)) = made.get(ask_key) else {
                    return Err(format!("a link to {to} from ask {ask_key}, not made yet"));
                };
                if !links.insert((s.clone(), t.clone(), to.clone())) {
                    return Err(format!("{t:?} linked to {to} twice"));
                }
            }
        }
    }
    Ok(links)
}

fn set(rows: &[(&str, &str, &str)]) -> BTreeSet<(String, String, String)> {
    rows.iter()
        .map(|(s, t, e)| (s.to_string(), t.to_string(), e.to_string()))
        .collect()
}

/// Pattern A. A manager is asked for a plan and writes it; it starts a worker, and in a later turn (woken on a job,
/// no user message between) writes a task; a steer reaches it mid-turn and its writes after that are the steer's. The
/// worker writes in any order against all of that and keeps the ask it inherited. A chat that leads to no work, and a
/// note (no `asked` link reaches one), make nothing. Edges: the worker's writes come after its start (the hub starts
/// it before its agent runs); the manager's end comes after its last write (the session is gone after its tools
/// answered); a steer's writes come after its delivery (the manager's own order).
#[test]
fn every_order_links_every_write() {
    let mut p = Partial::new();
    let m = p.source(
        "manager",
        vec![
            said("m", "plan the cache", "manager"),
            wrote("m", "plan:cache"),
            started(Some("m"), "w"),
            wrote("m", "task:t1"),
            steer("m", "and the docs"),
            wrote("m", "task:t2"),
            wrote("m", "note:n1"),
        ],
    );
    let w = p.source("worker", vec![wrote("w", "task:t3"), wrote("w", "spec:s1")]);
    p.source(
        "chat",
        vec![
            said("c", "what is a cache", "chat"),
            wrote("c", "note:n2"),
            gone("c"),
        ],
    );
    let end = p.source("end", vec![gone("m"), started(None, "u")]);
    // sessions resumed after a restart: one restored from its last message, one with none to restore from (what it
    // wrote while resuming links to nothing)
    p.source(
        "resumed",
        vec![
            restoring("r"),
            restored("r", "resume me", None),
            wrote("r", "plan:r1"),
        ],
    );
    p.source(
        "bare",
        vec![
            restoring("b"),
            wrote("b", "task:b1"),
            AskEv::NoRestore {
                session: "b".into(),
            },
        ],
    );
    p.before((m, 2), (w, 0));
    p.before((m, 6), (end, 0));
    let want = set(&[
        ("m", "plan the cache", "plan:cache"),
        ("m", "plan the cache", "session:w"),
        ("m", "plan the cache", "task:t1"),
        ("m", "plan the cache", "task:t3"),
        ("m", "plan the cache", "spec:s1"),
        ("m", "and the docs", "task:t2"),
        ("r", "resume me", "plan:r1"),
    ]);
    let r = every_order(&p, Bound::default(), Harness::default, |h, _| {
        let got = links_of(&h.outs)?;
        if got != want {
            return Err(format!("links {got:?}"));
        }
        let made = h
            .outs
            .iter()
            .filter(|o| matches!(o, AskOut::Create { .. }))
            .count();
        if made != 3 {
            return Err(format!("{made} asks made"));
        }
        Ok(())
    });
    assert!(r.orders > 100, "{} orders", r.orders);
}

/// Pattern D. A user message makes no ask until something links to it: none for a chat, none for a note.
#[test]
fn no_ask_without_work() {
    let mut c = AskCore::new();
    assert_eq!(c.step(said("c", "hello", "chat")), []);
    assert_eq!(c.step(wrote("c", "note:n")), []);
    assert_eq!(c.step(said("c", "and now?", "chat")), []);
    assert_eq!(c.step(gone("c")), []);
    // the next write is linked, and the ask is made then, with its words
    let mut c = AskCore::new();
    c.step(said("m", "add a cache", "manager"));
    let out = c.step(wrote("m", "plan:p"));
    assert!(
        matches!(&out[..], [AskOut::Create { text, channel, session, .. }, AskOut::Link { to, .. }]
            if text == "add a cache" && channel == "manager" && session == "m" && to == "plan:p"),
        "{out:?}"
    );
    // a second write to the same plan links nothing new
    assert_eq!(c.step(wrote("m", "plan:p")), []);
}

/// Pattern D. A steer becomes the current ask when it is delivered: the writes before it stay the first ask's, those
/// after are the steer's, in the session's channel; a worker started after it inherits the steer.
#[test]
fn steer_becomes_current_on_delivery() {
    let mut c = AskCore::new();
    let mut outs = c.step(said("m", "first", "manager"));
    outs.extend(c.step(wrote("m", "task:a")));
    outs.extend(c.step(steer("m", "second")));
    outs.extend(c.step(wrote("m", "task:b")));
    outs.extend(c.step(started(Some("m"), "w")));
    outs.extend(c.step(wrote("w", "task:c")));
    assert_eq!(
        links_of(&outs).unwrap(),
        set(&[
            ("m", "first", "task:a"),
            ("m", "second", "task:b"),
            ("m", "second", "session:w"),
            ("m", "second", "task:c"),
        ])
    );
    assert!(
        outs.iter()
            .any(|o| matches!(o, AskOut::Create { text, channel, .. } if text == "second" && channel == "manager")),
        "{outs:?}"
    );
}

/// Pattern D. Records the hub did not see a session write get no ask: an import, the scan's or the user's own
/// writes, and a session's write before any user message.
#[test]
fn imported_records_get_none() {
    let row = |session: Option<&str>, imported: bool| Written {
        tx: 7,
        session: session.map(str::to_string),
        imported,
        entity: "plan:p".into(),
        kind: "plan".into(),
    };
    assert_eq!(write_of(&row(None, false)), None);
    assert_eq!(write_of(&row(Some("m"), true)), None);
    assert_eq!(write_of(&row(None, true)), None);
    assert_eq!(write_of(&row(Some("m"), false)), Some(wrote("m", "plan:p")));
    // a session never asked anything writes: nothing
    let mut c = AskCore::new();
    assert_eq!(c.step(wrote("m", "plan:p")), []);
    assert_eq!(c.step(started(Some("m"), "w")), []);
    assert_eq!(c.step(wrote("w", "task:t")), []);
}

// ---- a restart: the current ask is rebuilt from the session's last user message ----

fn restoring(session: &str) -> AskEv {
    AskEv::Restoring {
        session: session.into(),
    }
}

fn restored(session: &str, text: &str, adopt: Option<&str>) -> AskEv {
    AskEv::Restore {
        session: session.into(),
        text: text.into(),
        channel: "chat".into(),
        message_id: Some("message:1".into()),
        at: 5.0,
        adopt: adopt.map(str::to_string),
    }
}

fn run(core: &mut AskCore, evs: Vec<AskEv>) -> Vec<AskOut> {
    evs.into_iter().flat_map(|e| core.step(e)).collect()
}

/// A restart before the ask entity was written (the last message led to no work yet): the first write after it makes
/// the ask once and links it.
#[test]
fn a_restart_before_the_ask_was_written_makes_it_at_the_first_link() {
    let mut core = AskCore::new();
    let outs = run(
        &mut core,
        vec![
            restoring("m"),
            restored("m", "plan the cache", None),
            wrote("m", "plan:cache"),
            wrote("m", "task:t1"),
        ],
    );
    assert_eq!(
        links_of(&outs).unwrap(),
        set(&[
            ("m", "plan the cache", "plan:cache"),
            ("m", "plan the cache", "task:t1")
        ])
    );
    assert_eq!(
        outs.iter()
            .filter(|o| matches!(o, AskOut::Create { .. }))
            .count(),
        1
    );
}

/// A restart after the ask entity was written: it is adopted, never made again, and a write links to it.
#[test]
fn a_restart_after_the_ask_was_written_adopts_it_and_makes_no_second() {
    let mut core = AskCore::new();
    let outs = run(
        &mut core,
        vec![
            restoring("m"),
            restored("m", "plan the cache", Some("ask:7")),
            wrote("m", "task:t2"),
        ],
    );
    assert!(
        !outs.iter().any(|o| matches!(o, AskOut::Create { .. })),
        "{outs:?}"
    );
    assert!(
        outs.iter()
            .any(|o| matches!(o, AskOut::Adopt { id, .. } if id == "ask:7")),
        "{outs:?}"
    );
    assert!(
        outs.iter()
            .any(|o| matches!(o, AskOut::Link { to, .. } if to == "task:t2"))
    );
}

/// Two restarts in a row, and a restore twice in one: the second never makes another ask (a restart is a new core, so
/// it adopts the entity the first made; in one core the second restore is ignored).
#[test]
fn two_restarts_in_a_row_make_one_ask() {
    // restart 1: the ask is made at the first link
    let mut one = AskCore::new();
    let outs = run(
        &mut one,
        vec![
            restoring("m"),
            restored("m", "plan", None),
            wrote("m", "plan:p"),
        ],
    );
    assert_eq!(
        outs.iter()
            .filter(|o| matches!(o, AskOut::Create { .. }))
            .count(),
        1
    );
    // restart 2: a new core adopts that entity, and a second restore in it changes nothing
    let mut two = AskCore::new();
    let outs = run(
        &mut two,
        vec![
            restoring("m"),
            restored("m", "plan", Some("ask:1")),
            restored("m", "plan", Some("ask:1")),
            wrote("m", "task:t"),
        ],
    );
    assert!(
        !outs.iter().any(|o| matches!(o, AskOut::Create { .. })),
        "{outs:?}"
    );
    assert_eq!(
        outs.iter()
            .filter(|o| matches!(o, AskOut::Adopt { .. }))
            .count(),
        1
    );
}

/// A write that arrives while the session is being resumed (read from the log before its restore is told) waits for the
/// ask and links to it; a user message that arrives first is the current ask instead, and the restore changes nothing.
#[test]
fn a_write_during_the_restore_waits_for_the_ask() {
    let mut core = AskCore::new();
    let outs = run(&mut core, vec![restoring("m"), wrote("m", "task:early")]);
    assert!(outs.is_empty(), "{outs:?}");
    let outs = run(&mut core, vec![restored("m", "plan", Some("ask:3"))]);
    assert!(
        outs.iter()
            .any(|o| matches!(o, AskOut::Link { to, .. } if to == "task:early"))
    );
    // a live message wins over the restore
    let mut core = AskCore::new();
    let outs = run(
        &mut core,
        vec![
            restoring("m"),
            said("m", "a new thing", "chat"),
            restored("m", "an old thing", Some("ask:3")),
            wrote("m", "task:t"),
        ],
    );
    let links = links_of(&outs).unwrap();
    assert_eq!(links, set(&[("m", "a new thing", "task:t")]));
}

/// No user message to restore from: the held writes link to nothing (never to a guess), and later ones neither until
/// the next message.
#[test]
fn nothing_to_restore_links_nothing() {
    let mut core = AskCore::new();
    let outs = run(
        &mut core,
        vec![
            restoring("w"),
            wrote("w", "task:early"),
            AskEv::NoRestore {
                session: "w".into(),
            },
            wrote("w", "task:late"),
        ],
    );
    assert!(outs.is_empty(), "{outs:?}");
}
