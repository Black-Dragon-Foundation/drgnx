//! The map's navigation for the native view model (pure, [D]): the links, `then` and the walking orders, against the
//! editor's own navigation on the 30-agent fixture and on small scenarios.
//!
//! The golden (`tests/golden/nav-thirty-1600.json`) was recorded from the editor's navigation
//! (`drgnx-work-nav-move`, `drgnx-work-nav-chain`, `drgnx-work-map--outline-ids`, `drgnx-work-nav--team`) over the
//! frame in `tests/golden/nav-thirty-1600-frame.json`, which `UPDATE_VEGVISIR_GOLDEN=1 cargo test -p vegvisir --test
//! nav` writes from this crate's layout of the fixture.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde_json::{Value, json};
use vegvisir::layout::{Layout, layout};
use vegvisir::nav::{self, Links};
use vegvisir::{Core, Event, ItemId, Model, ViewState, fixture};

fn model_of(events: Vec<Event>) -> Model {
    let mut c = Core::new();
    for e in events {
        c.step(e);
    }
    c.model().clone()
}

fn view(width: u32) -> ViewState {
    ViewState {
        width_units: width,
        ..ViewState::default()
    }
}

/// The items a full frame of `l` shows with no filter and nothing collapsed: those it places.
fn placed(l: &Layout) -> BTreeSet<ItemId> {
    l.at.keys().cloned().collect()
}

fn id(s: &str) -> ItemId {
    ItemId(s.to_string())
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.json"))
}

/// The frame the hub sends for the fixture at width 376 (1600 px), as `work/map/subscribe` answers it.
fn frame_json(m: &Model, l: &Layout, ids: &BTreeSet<ItemId>) -> Value {
    let items: Vec<Value> = m
        .items()
        .into_values()
        .filter(|it| ids.contains(&it.id))
        .map(|it| json!(it))
        .collect();
    let edges: Vec<Value> = m
        .edges()
        .into_iter()
        .filter(|e| ids.contains(&e.from) && ids.contains(&e.to))
        .map(|e| json!(e))
        .collect();
    json!({"version": 1, "items": items, "edges": edges, "layout": l,
           "needs_you": m.needs_you(), "chips": []})
}

#[test]
fn links_match_the_frozen_lisp_on_the_30_agent_fixture() {
    let m = model_of(fixture::thirty());
    let l = layout(&m, &view(376), None);
    let ids = placed(&l);
    let frame = serde_json::to_string_pretty(&frame_json(&m, &l, &ids)).expect("a frame") + "\n";
    let frame_path = golden_path("nav-thirty-1600-frame");
    if std::env::var_os("UPDATE_VEGVISIR_GOLDEN").is_some() {
        std::fs::write(&frame_path, &frame).expect("the frame is written");
    }
    assert_eq!(
        std::fs::read_to_string(&frame_path).expect("the recorded frame"),
        frame,
        "the fixture's frame moved: record the golden again from the editor's navigation"
    );
    let golden: Value = serde_json::from_str(
        &std::fs::read_to_string(golden_path("nav-thirty-1600")).expect("the golden"),
    )
    .expect("golden JSON");
    let opt = |v: &Value| v.as_str().map(id);
    let links = nav::links(&m, &l, &ids);
    let mut want = BTreeMap::new();
    for (k, v) in golden["links"].as_object().expect("links") {
        want.insert(
            id(k),
            Links {
                up: opt(&v["up"]),
                down: opt(&v["down"]),
                left: opt(&v["left"]),
                right: opt(&v["right"]),
                then: opt(&v["then"]),
            },
        );
    }
    assert_eq!(links.len(), want.len());
    for (k, w) in &want {
        assert_eq!(&links[k], w, "{k}");
    }
    let list = |name: &str| -> Vec<ItemId> {
        golden[name]
            .as_array()
            .expect("a list")
            .iter()
            .map(|v| id(v.as_str().expect("an id")))
            .collect()
    };
    assert_eq!(nav::outline(&m, &ids), list("outline"));
    assert_eq!(nav::team(&m, &ids), list("team"));
    assert_eq!(nav::needs_you(&m, &ids), list("needs-you"));
}

/// An ask that led to a spec, the spec's plan with one task, an agent on it with a subagent, and (EXTRA) more.
fn small(extra: &str) -> Model {
    model_of(fixture::from_json(&format!(
        r#"{{"asks": [{{"key": "1", "text": "make it fast", "to": ["spec:s"]}}],
            "specs": [{{"id": "s", "title": "S"}}],
            "plans": [{{"id": "p", "title": "P", "rank": 2, "spec": "s"}},
                      {{"id": "q", "title": "Q", "rank": 1}}],
            "tasks": [{{"id": "t", "plan": "p", "title": "T"}}, {{"id": "u", "plan": "q", "title": "U"}}],
            "agents": [{{"id": "a", "name": "A", "state": "running", "seq": 1, "task": "t", "branch": "r/a"}},
                       {{"id": "a/x2", "name": "X2", "state": "running", "seq": 5}},
                       {{"id": "a/x1", "name": "X1", "state": "running", "seq": 4}},
                       {{"id": "b", "name": "B", "state": "running", "seq": 2, "task": "u"}},
                       {{"id": "c", "name": "C", "state": "running", "seq": 3}}{extra}]}}"#
    )))
}

#[test]
fn missing_level_goes_to_the_lowest_ancestor() {
    let m = small("");
    // the plans' layer collapsed: the agent's own parent has no place
    let mut v = view(376);
    v.collapsed.insert(3);
    let l = layout(&m, &v, None);
    assert!(!l.at.contains_key(&id("plan:p")));
    let ids: BTreeSet<ItemId> = m.items().into_keys().collect();
    let links = nav::links(&m, &l, &ids);
    assert_eq!(links[&id("agent:a")].up, Some(id("spec:s")));
    assert_eq!(links[&id("spec:s")].up, Some(id("ask:1")));
    // nothing above the ask
    assert_eq!(links[&id("ask:1")].up, None);
    // an unplaced item has no arrows
    assert_eq!(links[&id("plan:p")].left, None);
    assert_eq!(links[&id("plan:p")].down, None);
}

#[test]
fn then_is_the_last_sorted_up() {
    let m = small("");
    let l = layout(&m, &view(376), None);
    let links = nav::links(&m, &l, &placed(&l));
    // up from the agent: the ask, the spec and the plan; the last by layer is the plan
    assert_eq!(links[&id("agent:a")].then, Some(id("plan:p")));
    // a subagent's last is its agent
    assert_eq!(links[&id("agent:a/x1")].then, Some(id("agent:a")));
    // an agent with nothing above it
    assert_eq!(links[&id("agent:c")].then, None);
    assert_eq!(links[&id("ask:1")].then, None);
}

#[test]
fn team_order_puts_subagents_after_parent() {
    let m = small("");
    let l = layout(&m, &view(376), None);
    let ids = placed(&l);
    // plan q ranks first (b), then p (a, its subagents by start order), then no plan (c)
    assert_eq!(
        nav::outline(&m, &ids),
        vec![id("agent:b"), id("agent:a"), id("agent:c")]
    );
    assert_eq!(
        nav::team(&m, &ids),
        vec![
            id("agent:b"),
            id("agent:a"),
            id("agent:a/x1"),
            id("agent:a/x2"),
            id("agent:c")
        ]
    );
}

#[test]
fn needs_you_lists_targets() {
    let m = small(
        r#", {"id": "d", "name": "D", "state": "needs-you", "seq": 6},
             {"id": "e", "name": "E", "state": "needs-you", "seq": 7}],
            "cards": [{"id": "k2", "kind": "push", "about": ["agent:b"], "text": "push?", "open": true},
                      {"id": "k1", "kind": "question", "about": ["agent:e", "agent:c"], "text": "which?", "open": true},
                      {"id": "k3", "kind": "question", "about": ["agent:zz"], "text": "gone", "open": true}"#,
    );
    let l = layout(&m, &view(376), None);
    let ids = placed(&l);
    // the cards by id (k1's first shown item, k2's; k3 is about nothing shown), then d: it needs you with no card (e
    // has one)
    assert_eq!(
        nav::needs_you(&m, &ids),
        vec![id("agent:c"), id("agent:b"), id("agent:d")]
    );
}
