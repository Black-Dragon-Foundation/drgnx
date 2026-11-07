//! The store in every order of envs, rows, resyncs and hub restarts. An editor model replays every patch with the
//! rules of `docs/develop/hub.md` ("Rows") and must end holding exactly the rows last given for each class it sent
//! an env for.

use super::{Key, Store, is_reset};
use drgnx_rows::{Op, Patch, Row, RowBuilder};
use runstav::methods::view::{Display, ViewEnv};
use skuld::{Bound, Core, Partial, every_order};
use std::collections::BTreeMap;

const CONN: u64 = 1;

/// What the store is fed.
#[derive(Clone, Debug)]
enum Act {
    /// The editor's env for CLASS at EPOCH (WIDTH px).
    Env(&'static str, u64, u32),
    /// The view's builder gives CLASS N rows (generation G).
    Rows(&'static str, u32, u32),
    /// The editor of CLASS asks for its rows again.
    Resync(&'static str),
    /// The hub restarts: a new instance, nothing kept.
    Restart,
}

/// What the store sent, in order.
#[derive(Clone, Debug)]
enum Out {
    Env(&'static str, u64),
    Patch(Patch),
    Restart,
}

fn key(class: &str) -> Key {
    (CONN, "v".into(), class.into())
}

fn env(class: &str, epoch: u64, width: u32) -> ViewEnv {
    ViewEnv {
        view: "v".into(),
        class: class.into(),
        epoch,
        display: Display::Gui,
        scale: 1.0,
        fonts: vec![],
        cell: (8, 16),
        width_px: width,
        palette: vec![],
        tty_widths: vec![],
        tz: String::new(),
        reduced_motion: false,
    }
}

fn rows(class: &str, n: u32, g: u32) -> Vec<Row> {
    (0..n)
        .map(|i| {
            let mut b = RowBuilder::new(format!("r{i}"));
            // a row's text changes with the generation only for every other row, so diffs mix kept and replaced
            b.push(
                &format!("{class} {i} {}", if i % 2 == 0 { g } else { 0 }),
                Some("drgnx-dim"),
            );
            b.finish()
        })
        .collect()
}

/// The hub's store plus the view builder's latest rows per class.
struct World {
    store: Store,
    next_hub: u64,
    given: BTreeMap<&'static str, Vec<Row>>,
    out: Vec<Out>,
}

impl World {
    fn new() -> Self {
        World {
            store: Store::new(100),
            next_hub: 101,
            given: BTreeMap::new(),
            out: vec![],
        }
    }

    fn publish(&mut self, class: &'static str) {
        let Some(r) = self.given.get(class).cloned() else {
            return;
        };
        if let Some(p) = self.store.publish(&key(class), r, &[]) {
            self.out.push(Out::Patch(p));
        }
    }

    fn act(&mut self, a: Act) {
        match a {
            Act::Env(class, epoch, width) => {
                self.store.env(CONN, env(class, epoch, width));
                self.out.push(Out::Env(class, epoch));
                self.publish(class);
            }
            Act::Rows(class, n, g) => {
                self.given.insert(class, rows(class, n, g));
                self.publish(class);
            }
            Act::Resync(class) => {
                if let Some(p) = self.store.resync(&key(class), &[]) {
                    self.out.push(Out::Patch(p));
                }
            }
            Act::Restart => {
                self.store = Store::new(self.next_hub);
                self.next_hub += 1;
                self.out.push(Out::Restart);
            }
        }
    }
}

/// An editor's view of one class, as the inserter keeps it.
#[derive(Default)]
struct Held {
    hub: Option<u64>,
    version: u64,
    epoch: u64,
    rows: Vec<Row>,
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

/// Replays OUT as an editor would and checks the rules: nothing before an env; after an env with a new epoch, or a
/// restart, the next patch is a reset; every other patch names the hub, version and epoch the editor holds; at the
/// end each class with an env holds the rows last given.
fn check(w: &World) -> Result<(), String> {
    let mut held: BTreeMap<&str, Held> = BTreeMap::new();
    // classes with an env from the current hub
    let mut has_env: BTreeMap<&str, bool> = BTreeMap::new();
    let mut reset_due: BTreeMap<&str, bool> = BTreeMap::new();
    let mut hub = 100;
    for o in &w.out {
        match o {
            Out::Restart => {
                hub += 1;
                has_env.clear();
                for h in held.values_mut() {
                    // the inserter forgets the version and the hub on a disconnect
                    h.hub = None;
                }
            }
            Out::Env(class, epoch) => {
                let h = held.entry(class).or_default();
                if *epoch != h.epoch || has_env.get(class) != Some(&true) {
                    reset_due.insert(class, true);
                }
                h.epoch = *epoch;
                has_env.insert(class, true);
            }
            Out::Patch(p) => {
                let class = p.class.as_str();
                if has_env.get(class) != Some(&true) {
                    return Err(format!("a patch for {class} with no env: {p:?}"));
                }
                if p.hub != hub {
                    return Err(format!("a patch of hub {} from hub {hub}", p.hub));
                }
                let h = held.get_mut(class).expect("an env came first");
                if p.env_epoch != h.epoch {
                    return Err(format!(
                        "a patch for epoch {} at epoch {}",
                        p.env_epoch, h.epoch
                    ));
                }
                if is_reset(p) {
                    reset_due.insert(class, false);
                } else {
                    if reset_due.get(class) == Some(&true) {
                        return Err(format!("not a reset after a new env or hub: {p:?}"));
                    }
                    if h.hub != Some(p.hub) || h.version != p.base {
                        return Err(format!(
                            "base {} of hub {} on version {} of {:?}",
                            p.base, p.hub, h.version, h.hub
                        ));
                    }
                }
                apply(&mut h.rows, &p.ops)?;
                h.hub = Some(p.hub);
                h.version = p.version;
            }
        }
    }
    for (class, on) in &has_env {
        let want = w.given.get(class).cloned().unwrap_or_default();
        if *on && w.given.contains_key(class) && held.get(class).map(|h| &h.rows) != Some(&want) {
            return Err(format!(
                "{class} holds {:?}, not {want:?}",
                held.get(class).map(|h| &h.rows)
            ));
        }
    }
    Ok(())
}

macro_rules! sim {
    ($name:ident { $($v:ident),+ }) => {
        #[derive(Clone, Debug)]
        #[allow(dead_code)]
        enum $name { $($v(Act)),+ }
        skuld::events!($name { $($v),+ });
        impl $name {
            fn act(self) -> Act {
                match self { $($name::$v(a) => a),+ }
            }
        }
        impl Core for Sim<$name> {
            type Event = $name;
            fn step(&mut self, ev: $name) -> Vec<$name> {
                self.0.act(ev.act());
                vec![]
            }
        }
    };
}

struct Sim<E>(World, std::marker::PhantomData<E>);

fn run<E: Clone + std::fmt::Debug + skuld::Events>(p: &Partial<E>)
where
    Sim<E>: Core<Event = E>,
{
    every_order(
        p,
        Bound::default(),
        || Sim(World::new(), std::marker::PhantomData),
        |s, _| check(&s.0),
    );
}

sim!(EpochEv { Env, Rows });

#[test]
fn env_change_with_new_epoch_makes_next_patch_a_reset() {
    use EpochEv::*;
    let mut p = Partial::new();
    p.source(
        "editor",
        vec![
            Env(Act::Env("gui-1", 1, 400)),
            Env(Act::Env("gui-1", 1, 300)),
            Env(Act::Env("gui-1", 2, 300)),
        ],
    );
    p.source(
        "builder",
        vec![
            Rows(Act::Rows("gui-1", 3, 1)),
            Rows(Act::Rows("gui-1", 4, 2)),
            Rows(Act::Rows("gui-1", 2, 3)),
        ],
    );
    run(&p);
}

sim!(ResyncEv { Env, Rows, Resync });

#[test]
fn stale_base_patch_is_not_sent_after_resync() {
    use ResyncEv::*;
    let mut p = Partial::new();
    p.source(
        "editor",
        vec![
            Env(Act::Env("gui-1", 1, 400)),
            Resync(Act::Resync("gui-1")),
            Resync(Act::Resync("gui-1")),
        ],
    );
    p.source(
        "builder",
        vec![
            Rows(Act::Rows("gui-1", 3, 1)),
            Rows(Act::Rows("gui-1", 5, 2)),
            Rows(Act::Rows("gui-1", 1, 3)),
        ],
    );
    run(&p);
}

#[test]
fn two_classes_keep_two_row_sets() {
    use EpochEv::*;
    let mut p = Partial::new();
    p.source(
        "gui",
        vec![
            Env(Act::Env("gui-1", 1, 400)),
            Env(Act::Env("gui-1", 2, 400)),
        ],
    );
    p.source("tty", vec![Env(Act::Env("tty", 1, 80))]);
    p.source(
        "gui rows",
        vec![
            Rows(Act::Rows("gui-1", 3, 1)),
            Rows(Act::Rows("gui-1", 4, 2)),
        ],
    );
    p.source(
        "tty rows",
        vec![Rows(Act::Rows("tty", 2, 1)), Rows(Act::Rows("tty", 3, 2))],
    );
    run(&p);
}

sim!(RestartEv { Env, Rows, Restart });

#[test]
fn restart_never_matches_an_old_base() {
    use RestartEv::*;
    let mut p = Partial::new();
    // the editor's env, then (after the restart: it reconnects) the same env again
    let ed = p.source(
        "editor",
        vec![
            Env(Act::Env("gui-1", 1, 400)),
            Env(Act::Env("gui-1", 1, 400)),
        ],
    );
    let hub = p.source("hub", vec![Restart(Act::Restart)]);
    p.source(
        "builder",
        vec![
            Rows(Act::Rows("gui-1", 3, 1)),
            Rows(Act::Rows("gui-1", 3, 2)),
            Rows(Act::Rows("gui-1", 4, 3)),
        ],
    );
    p.before((ed, 0), (hub, 0)).before((hub, 0), (ed, 1));
    run(&p);
}

#[test]
fn no_env_builds_no_rows() {
    use EpochEv::*;
    let mut p = Partial::new();
    let b = p.source(
        "builder",
        vec![
            Rows(Act::Rows("gui-1", 3, 1)),
            Rows(Act::Rows("gui-1", 2, 2)),
        ],
    );
    let e = p.source("editor", vec![Env(Act::Env("gui-1", 1, 400))]);
    // rows given before any env: nothing is sent until the env comes
    p.before((b, 0), (e, 0));
    run(&p);
    let mut w = World::new();
    w.act(Act::Rows("gui-1", 3, 1));
    assert!(w.out.is_empty(), "no env, yet {:?}", w.out);
    w.act(Act::Env("gui-1", 1, 400));
    assert!(
        matches!(w.out.as_slice(), [Out::Env(..), Out::Patch(p)] if is_reset(p)),
        "{:?}",
        w.out
    );
}

/// The fixture view's labels (`__test_view_rows`'s `labels`), fitted with the class's fonts: a GUI class by pixels
/// (the editor's advances here: 10 px a char), a terminal class by columns of its cell.
#[test]
fn fixture_labels_are_fitted_per_class() {
    use drgnx_rows::fit::FontSet;
    let labels = vec![
        ("a".to_owned(), "abcdefghij".to_owned(), 60),
        ("b".to_owned(), "abc".to_owned(), 60),
    ];
    let mut set = FontSet::new();
    set.set_role("ui", None, 10.0);
    let answers: Vec<(String, char, f32)> = "abcdefghij…"
        .chars()
        .map(|c| ("ui".to_owned(), c, 10.0))
        .collect();
    set.glyphs(&answers);
    let gui = super::label_rows(&labels, &env("g", 1, 600), &set);
    // 60 px less the 10 px slack: four chars and the ellipsis; then the stop's placeholder and the rest
    assert_eq!(gui[0].text, "abcd… |");
    assert_eq!(gui[0].stops, vec![(5, 60)]);
    assert_eq!(gui[1].text, "abc |");
    let mut tty = env("t", 1, 600);
    tty.display = Display::Tty;
    tty.cell = (10, 20);
    // 60 px of 10 px cells: 6 columns, the ellipsis one of them
    let t = super::label_rows(&labels, &tty, &FontSet::new());
    assert_eq!(t[0].text, "abcde… |");
}

/// An acknowledged view (a terminal's): one patch in flight per (view, class); rows built meanwhile wait, the newest
/// winning, and go as one patch on the ack of the version sent. An ack of another version releases nothing.
#[test]
fn ack_clears_in_flight() {
    let mut s = Store::new(5);
    let k = key("gui-1");
    s.options(
        CONN,
        "v",
        super::ViewOpts {
            ack: true,
            epoch_reset: false,
        },
    );
    s.env(CONN, env("gui-1", 1, 400));
    let first = s.publish(&k, rows("gui-1", 2, 1), &[]).expect("the reset");
    assert!(is_reset(&first) && s.in_flight(&k));
    assert_eq!(
        s.publish(&k, rows("gui-1", 3, 2), &[]),
        None,
        "held while v1 is in flight"
    );
    assert_eq!(
        s.publish(&k, rows("gui-1", 4, 3), &[]),
        None,
        "held while v1 is in flight"
    );
    assert_eq!(
        s.ack(&k, 0),
        None,
        "an ack of an older version releases nothing"
    );
    let next = s.ack(&k, 1).expect("the ack releases the waiting rows");
    assert_eq!((next.base, next.version), (1, 2));
    let mut held = rows("gui-1", 2, 1);
    apply(&mut held, &next.ops).unwrap();
    assert_eq!(held, rows("gui-1", 4, 3), "the newest rows, as one patch");
    assert!(s.in_flight(&k));
    // a resync answers at once, with the newest rows, and that reset is what is in flight now
    assert_eq!(s.publish(&k, rows("gui-1", 1, 4), &[]), None);
    let r = s.resync(&k, &[]).expect("a resync is never held");
    assert!(is_reset(&r) && r.version == 3);
    assert!(matches!(r.ops.as_slice(), [Op::Reset(x)] if *x == rows("gui-1", 1, 4)));
    assert_eq!(s.ack(&k, 3), None, "nothing waits after the reset");
    assert!(!s.in_flight(&k));
    assert!(
        s.publish(&k, rows("gui-1", 2, 5), &[]).is_some(),
        "acked: the next patch goes at once"
    );
    // a view that asked for no acks is never held
    let mut plain = Store::new(6);
    plain.env(CONN, env("gui-1", 1, 400));
    assert!(plain.publish(&k, rows("gui-1", 2, 1), &[]).is_some());
    assert!(plain.publish(&k, rows("gui-1", 3, 2), &[]).is_some());
    assert!(!plain.in_flight(&k));
}

/// A lost ack never stalls a view: the editor that reconnects is a new connection, and its first patch goes at once.
#[test]
fn reconnect_clears_unacked() {
    let mut s = Store::new(5);
    let opts = super::ViewOpts {
        ack: true,
        epoch_reset: false,
    };
    s.options(CONN, "v", opts);
    s.env(CONN, env("gui-1", 1, 400));
    let k = key("gui-1");
    assert!(s.publish(&k, rows("gui-1", 2, 1), &[]).is_some());
    assert!(s.in_flight(&k), "v1 is not acknowledged");
    s.gone(CONN);
    assert!(!s.in_flight(&k));
    let k2: Key = (CONN + 1, "v".into(), "gui-1".into());
    s.options(CONN + 1, "v", opts);
    s.env(CONN + 1, env("gui-1", 1, 400));
    let p = s
        .publish(&k2, rows("gui-1", 2, 2), &[])
        .expect("the new connection's reset");
    assert!(is_reset(&p) && p.base == 0 && p.version == 1);
    assert!(s.in_flight(&k2));
}

/// A view exempt from the epoch reset (a terminal's) answers a new epoch with a diff, echoing the new epoch.
#[test]
fn epoch_exempt_view_answers_a_new_epoch_with_a_diff() {
    let mut s = Store::new(5);
    let k = key("gui-1");
    s.options(
        CONN,
        "v",
        super::ViewOpts {
            ack: false,
            epoch_reset: false,
        },
    );
    s.env(CONN, env("gui-1", 1, 400));
    assert!(
        s.publish(&k, rows("gui-1", 2, 1), &[])
            .is_some_and(|p| is_reset(&p))
    );
    s.env(CONN, env("gui-1", 2, 400));
    let p = s.publish(&k, rows("gui-1", 3, 2), &[]).expect("a patch");
    assert!(!is_reset(&p), "{p:?}");
    assert_eq!(p.env_epoch, 2);
}

/// A small model: two nodes with a label each (the second's GEN), one edge, one list.
fn doc(gen_: u32) -> super::model::Doc {
    use serde_json::json;
    let mut d = super::model::Doc {
        descriptor: json!({"scheme": "links", "lists": ["all"]}),
        ..Default::default()
    };
    d.nodes.insert(
        "a".into(),
        json!({"id": "a", "kind": "k", "fields": [["label", "A"]]}),
    );
    d.nodes.insert(
        "b".into(),
        json!({"id": "b", "kind": "k", "fields": [["label", format!("B{gen_}")]]}),
    );
    d.edges.insert(("a".into(), "b".into(), "came-from".into()));
    d.lists.insert("all".into(), vec!["a".into(), "b".into()]);
    d
}

/// The model's ops, parsed back from its one string.
fn ops_of(m: &runstav::methods::view::ViewModel) -> Vec<serde_json::Value> {
    let v: serde_json::Value = serde_json::from_str(&m.model).expect("one JSON string");
    v["ops"].as_array().expect("ops").clone()
}

/// [D] The model goes as one string field: the event's `model` is a JSON string holding `{"ops": [...]}`, never an
/// object the editor's reader would make Lisp data of.
#[test]
fn model_is_one_string_field() {
    let mut s = Store::new(7);
    let m = s.publish_model(CONN, "v", doc(1)).expect("a first model");
    let ev = serde_json::to_value(&m).expect("the event");
    assert!(ev["model"].is_string(), "{ev}");
    assert_eq!((m.hub, m.base, m.version), (7, 0, 1));
    assert!(ops_of(&m)[0].get("reset").is_some());
    assert_eq!(ev["reset"], true, "the envelope says reset: {ev}");
    let m = s.publish_model(CONN, "v", doc(2)).expect("a changed model");
    assert!(!m.reset);
    let ev = serde_json::to_value(&m).expect("the event");
    assert!(ev.get("reset").is_none(), "no reset key on a diff: {ev}");
}

/// [D] A patch names the model version its rows were built from; a view with no model names none.
#[test]
fn patch_names_its_model_version() {
    let mut s = Store::new(7);
    s.env(CONN, env("g", 1, 600));
    let p = s.publish(&key("g"), rows("g", 2, 1), &[]).expect("rows");
    assert_eq!(p.model, None);
    s.publish_model(CONN, "v", doc(1)).expect("a model");
    s.publish_model(CONN, "v", doc(2)).expect("a changed model");
    let p = s.publish(&key("g"), rows("g", 2, 2), &[]).expect("rows");
    assert_eq!(p.model, Some(2));
    assert_eq!(s.resync(&key("g"), &[]).expect("a reset").model, Some(2));
}

/// [D] A change only the model sees (a field the rows don't show) sends a model and no rows; nothing changed sends
/// neither.
#[test]
fn fields_only_change_sends_model_and_no_rows() {
    let mut s = Store::new(7);
    s.env(CONN, env("g", 1, 600));
    s.publish_model(CONN, "v", doc(1)).expect("a model");
    s.publish(&key("g"), rows("g", 2, 1), &[]).expect("rows");
    let m = s
        .publish_model(CONN, "v", doc(2))
        .expect("the field change");
    assert_eq!((m.base, m.version), (1, 2));
    let ops = ops_of(&m);
    assert_eq!(ops.len(), 1, "{ops:?}");
    assert_eq!(ops[0]["nodes"][0]["id"], "b");
    assert!(s.publish(&key("g"), rows("g", 2, 1), &[]).is_none());
    assert!(s.publish_model(CONN, "v", doc(2)).is_none());
}

/// [D] A hidden view's next model is a reset; a resync answers one too, and a closed view has none to resync.
#[test]
fn hidden_view_gets_no_model_then_reset() {
    let mut s = Store::new(7);
    s.publish_model(CONN, "v", doc(1)).expect("a model");
    s.model_hidden(CONN, "v");
    let m = s
        .publish_model(CONN, "v", doc(1))
        .expect("a reset, though unchanged");
    assert!(ops_of(&m)[0].get("reset").is_some());
    assert_eq!(m.version, 2);
    let r = s.resync_model(CONN, "v").expect("a resync");
    assert!(ops_of(&r)[0].get("reset").is_some());
    assert_eq!((r.base, r.version), (2, 3));
    s.close(CONN, "v");
    assert!(s.resync_model(CONN, "v").is_none());
}

/// [D] Removals: edges first, then the nodes; a list that went is sent empty.
#[test]
fn removals_send_edges_before_nodes() {
    let mut s = Store::new(7);
    s.publish_model(CONN, "v", doc(1)).expect("a model");
    let mut d = doc(1);
    d.nodes.remove("b");
    d.edges.clear();
    d.lists.clear();
    let ops = ops_of(&s.publish_model(CONN, "v", d).expect("removals"));
    assert!(ops[0]["edges"]["remove"].is_array(), "{ops:?}");
    assert_eq!(ops[1]["remove"], serde_json::json!(["b"]));
    assert_eq!(ops[2]["list"]["ids"], serde_json::json!([]));
}
